use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::{mpsc, oneshot};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SessionState {
    Idle,
    Working,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    User,
    Assistant,
    Tool,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct Message {
    pub role: Role,
    pub text: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub id: String,
    pub title: String,
    pub cwd: String,
    pub state: SessionState,
    pub messages: Vec<Message>,
    pub partial: String,
    #[serde(default)]
    pub changed_at: u64,
}

impl Session {
    pub fn valid(&self) -> bool {
        !self.id.is_empty()
            && self.id.len() <= 128
            && self
                .id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
            && self.title.len() <= 1024
            && self.cwd.len() <= 4096
            && self.messages.len() <= 2048
    }
}

#[derive(Serialize)]
pub struct Snapshot {
    pub hostname: String,
    pub sessions: Vec<Session>,
}

pub struct Entry {
    pub owner: u64,
    pub session: Session,
    pub commands: mpsc::Sender<String>,
}
pub struct Pending {
    pub owner: u64,
    pub session_id: String,
    pub result: oneshot::Sender<CommandResult>,
}
#[derive(Debug)]
pub struct CommandResult {
    pub ok: bool,
    pub error: Option<String>,
}

#[derive(Default)]
pub struct Registry {
    pub sessions: HashMap<String, Entry>,
    pub pending: HashMap<String, Pending>,
}

impl Registry {
    pub fn snapshot(&self, hostname: &str) -> Snapshot {
        Snapshot {
            hostname: hostname.to_owned(),
            sessions: self
                .sessions
                .values()
                .map(|entry| entry.session.clone())
                .collect(),
        }
    }

    pub fn remove_owner(&mut self, owner: u64) -> bool {
        let before = self.sessions.len();
        self.sessions.retain(|_, entry| entry.owner != owner);
        self.pending.retain(|_, request| request.owner != owner);
        before != self.sessions.len()
    }

    // A newer socket owns a duplicated ID; delayed frames and cleanup from the old
    // socket can never retake or remove it. Initial/reconnected idle is not a turn.
    pub fn update(
        &mut self,
        owner: u64,
        mut session: Session,
        commands: mpsc::Sender<String>,
    ) -> Result<bool, ()> {
        if !session.valid() {
            return Err(());
        }
        if self
            .sessions
            .get(&session.id)
            .is_some_and(|old| old.owner > owner)
        {
            return Err(());
        }
        let same = self
            .sessions
            .get(&session.id)
            .filter(|old| old.owner == owner);
        let turn = same.is_some_and(|old| {
            old.session.state == SessionState::Working && session.state == SessionState::Idle
        });
        session.changed_at = match same {
            Some(old) if old.session.state == session.state => old.session.changed_at,
            _ => now_millis(),
        };
        // A socket may switch sessions. Cancel requests targeting the old session.
        self.sessions
            .retain(|id, old| old.owner != owner || id == &session.id);
        self.pending
            .retain(|_, request| request.owner != owner || request.session_id == session.id);
        if let Some(old) = self.sessions.get(&session.id) {
            if old.owner != owner {
                let old_owner = old.owner;
                self.pending.retain(|_, request| {
                    request.owner != old_owner || request.session_id != session.id
                });
            }
        }
        self.sessions.insert(
            session.id.clone(),
            Entry {
                owner,
                session,
                commands,
            },
        );
        Ok(turn)
    }

    pub fn acknowledge(&mut self, owner: u64, request_id: &str, result: CommandResult) {
        let valid = self.pending.get(request_id).is_some_and(|request| {
            request.owner == owner
                && self
                    .sessions
                    .get(&request.session_id)
                    .is_some_and(|entry| entry.owner == owner)
        });
        if valid {
            if let Some(request) = self.pending.remove(request_id) {
                let _ = request.result.send(result);
            }
        }
    }
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    fn session(id: &str, state: SessionState) -> Session {
        Session {
            id: id.into(),
            title: "title".into(),
            cwd: "/tmp".into(),
            state,
            messages: vec![],
            partial: String::new(),
            changed_at: 0,
        }
    }
    #[test]
    fn turn_requires_connected_working_to_idle() {
        let mut registry = Registry::default();
        let (tx, _) = mpsc::channel(2);
        assert_eq!(
            registry.update(1, session("a", SessionState::Idle), tx.clone()),
            Ok(false)
        );
        assert_eq!(
            registry.update(1, session("a", SessionState::Working), tx.clone()),
            Ok(false)
        );
        assert_eq!(
            registry.update(1, session("a", SessionState::Idle), tx.clone()),
            Ok(true)
        );
        assert_eq!(
            registry.update(1, session("a", SessionState::Idle), tx.clone()),
            Ok(false)
        );
        registry.remove_owner(1);
        assert_eq!(
            registry.update(2, session("a", SessionState::Idle), tx),
            Ok(false)
        );
    }
    #[test]
    fn replacement_survives_old_socket_and_rejects_its_acks() {
        let mut registry = Registry::default();
        let (tx, _) = mpsc::channel(2);
        registry
            .update(1, session("a", SessionState::Working), tx.clone())
            .unwrap();
        registry
            .update(2, session("a", SessionState::Idle), tx.clone())
            .unwrap();
        let (result, mut received) = oneshot::channel();
        registry.pending.insert(
            "request".into(),
            Pending {
                owner: 2,
                session_id: "a".into(),
                result,
            },
        );
        registry.acknowledge(
            1,
            "request",
            CommandResult {
                ok: true,
                error: None,
            },
        );
        assert!(matches!(
            received.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        assert_eq!(
            registry.update(1, session("a", SessionState::Working), tx),
            Err(())
        );
        assert!(!registry.remove_owner(1));
        registry.acknowledge(
            2,
            "request",
            CommandResult {
                ok: true,
                error: None,
            },
        );
        assert!(received.try_recv().unwrap().ok);
        assert_eq!(registry.sessions["a"].session.state, SessionState::Idle);
    }
    #[test]
    fn switching_session_cancels_inflight_commands() {
        let mut registry = Registry::default();
        let (tx, _) = mpsc::channel(2);
        registry
            .update(1, session("a", SessionState::Idle), tx.clone())
            .unwrap();
        let (result, mut received) = oneshot::channel();
        registry.pending.insert(
            "request".into(),
            Pending {
                owner: 1,
                session_id: "a".into(),
                result,
            },
        );
        registry
            .update(1, session("b", SessionState::Idle), tx)
            .unwrap();
        assert!(matches!(
            received.try_recv(),
            Err(oneshot::error::TryRecvError::Closed)
        ));
        assert!(!registry.sessions.contains_key("a"));
    }
}
