use crate::cli::CommonArgs;
use crate::logging::LogFormat;
use crate::output::OutputMode;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Ctx {
    common_args: CommonArgs,
    working_dir: PathBuf,
}

impl Ctx {
    pub fn new(common_args: CommonArgs, working_dir: PathBuf) -> Self {
        Self {
            common_args,
            working_dir,
        }
    }

    pub fn is_automated(&self) -> bool {
        self.common_args.automated
    }

    pub fn output_mode(&self) -> OutputMode {
        self.common_args.output
    }

    pub fn log_format(&self) -> Option<LogFormat> {
        self.common_args.log_format
    }

    pub fn working_dir(&self) -> &Path {
        &self.working_dir
    }
}

#[cfg(test)]
mod tests {
    use super::Ctx;
    use crate::cli::CommonArgs;
    use crate::output::OutputMode;
    use std::path::{Path, PathBuf};

    #[test]
    fn ctx_exposes_automation_and_output() {
        let ctx = Ctx::new(
            CommonArgs {
                automated: true,
                output: OutputMode::Json,
                log_format: None,
            },
            PathBuf::from("/tmp/project"),
        );

        assert!(ctx.is_automated());
        assert_eq!(ctx.output_mode(), OutputMode::Json);
        assert_eq!(ctx.working_dir(), Path::new("/tmp/project"));
    }
}
