"""Decide whether robots.txt lets an automated visitor load a URL (RFC 9309).

The standard library's urllib.robotparser ignores the `*` and `$` path
patterns that the property portals rely on, so this implements the matching
rules itself: the longest matching rule wins, and Allow wins a tie.
"""

from __future__ import annotations

import re
from typing import List, Optional, Tuple
from urllib.parse import unquote, urlsplit

# The token this toolkit answers to in robots.txt, besides the `*` group.
AGENT_TOKEN = "jpx"

# Names under which sites address the assistant that drives this toolkit. A
# site that shuts any of them out of a URL has shut this toolkit out of it,
# whatever its `*` group says.
ASSISTANT_TOKENS = ("claude-user", "claudebot", "claude-web", "claude-searchbot", "anthropic-ai")

_RULE_KEYS = ("allow", "disallow", "crawl-delay")

Rule = Tuple[str, str]


def _groups(robots_txt: str) -> List[Tuple[List[str], List[Rule]]]:
    """(user agents, rules) for each group, in file order."""
    groups: List[Tuple[List[str], List[Rule]]] = []
    agents: List[str] = []
    rules: List[Rule] = []
    in_agent_run = False
    for raw in robots_txt.splitlines():
        line = raw.split("#", 1)[0].strip()
        if ":" not in line:
            continue
        key, value = (part.strip() for part in line.split(":", 1))
        key = key.lower()
        if key == "user-agent":
            if not in_agent_run and agents:
                groups.append((agents, rules))
                agents, rules = [], []
            agents.append(value.lower())
            in_agent_run = True
        elif key in _RULE_KEYS:
            in_agent_run = False
            if agents:
                rules.append((key, value))
    if agents:
        groups.append((agents, rules))
    return groups


def _rules_for(robots_txt: str, agent: str) -> List[Rule]:
    groups = _groups(robots_txt)
    token = agent.lower()
    named = [rules for agents, rules in groups if any(a != "*" and a in token for a in agents)]
    chosen = named or [rules for agents, rules in groups if "*" in agents]
    return [rule for rules in chosen for rule in rules]


def _permits(rules: List[Rule], target: str) -> bool:
    """Longest matching rule wins; Allow wins a tie; no matching rule permits."""
    best_len = -1
    verdict = True
    for kind, rule_path in rules:
        if kind == "crawl-delay" or not rule_path:
            continue
        if _pattern(rule_path).match(target):
            length = len(rule_path)
            if length > best_len or (length == best_len and kind == "allow"):
                best_len = length
                verdict = kind == "allow"
    return verdict


def _pattern(rule_path: str) -> "re.Pattern[str]":
    """A rule path as a regular expression over the percent-decoded URL.

    Both sides are decoded before comparing, so `[` in a rule matches `%5B`
    in a URL and the reverse. `*` is split out first, so an encoded `%2A`
    stays a literal asterisk.
    """
    anchored = rule_path.endswith("$")
    body = rule_path[:-1] if anchored else rule_path
    regex = ".*".join(re.escape(unquote(part)) for part in body.split("*"))
    return re.compile(regex + ("$" if anchored else ""))


def allowed(robots_txt: Optional[str], url: str, agent: str = AGENT_TOKEN) -> bool:
    """True when the robots.txt text permits `url`, both to this toolkit and to the assistant driving it.

    `robots_txt` is the file's text; None means the site has no robots.txt
    (a 404), which permits everything. What an unreachable or blocked
    robots.txt means is the caller's decision; see plan.robots_verdict.
    """
    if robots_txt is None:
        return True
    parts = urlsplit(url)
    target = unquote(parts.path or "/") + ("?" + unquote(parts.query) if parts.query else "")
    if not _permits(_rules_for(robots_txt, agent), target):
        return False
    for agents, rules in _groups(robots_txt):
        if any(a in ASSISTANT_TOKENS for a in agents) and not _permits(rules, target):
            return False
    return True


def crawl_delay(robots_txt: Optional[str], agent: str = AGENT_TOKEN) -> Optional[float]:
    """Crawl-delay in seconds for our group, when the site states one."""
    if not robots_txt:
        return None
    for kind, value in _rules_for(robots_txt, agent):
        if kind == "crawl-delay":
            try:
                return float(value)
            except ValueError:
                return None
    return None
