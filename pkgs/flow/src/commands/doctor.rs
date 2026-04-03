use crate::cli::DoctorArgs;
use crate::context::Ctx;
use crate::logging::tracing;
use crate::output::OutputMode;
use serde::Serialize;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DoctorOutput {
    pub cli_name: String,
    pub version: String,
    pub automated: bool,
    pub output_mode: OutputMode,
    pub working_dir: String,
}

pub fn execute(ctx: &Ctx, _args: DoctorArgs) -> anyhow::Result<DoctorOutput> {
    tracing::debug!(
        working_dir = %ctx.working_dir().display(),
        automated = ctx.is_automated(),
        output_mode = %ctx.output_mode(),
        "collecting doctor information"
    );

    Ok(DoctorOutput {
        cli_name: env!("CARGO_PKG_NAME").to_owned(),
        version: env!("CARGO_PKG_VERSION").to_owned(),
        automated: ctx.is_automated(),
        output_mode: ctx.output_mode(),
        working_dir: ctx.working_dir().display().to_string(),
    })
}

pub fn format_text(output: &DoctorOutput) -> String {
    format!(
        "flow {version}\nautomated: {automated}\noutput: {output_mode}\nworking_dir: {working_dir}",
        version = output.version,
        automated = output.automated,
        output_mode = output.output_mode,
        working_dir = output.working_dir,
    )
}

#[cfg(test)]
mod tests {
    use super::{DoctorOutput, format_text};
    use crate::output::OutputMode;

    #[test]
    fn formats_doctor_text_stably() {
        let output = DoctorOutput {
            cli_name: "flow".to_owned(),
            version: "0.1.0".to_owned(),
            automated: true,
            output_mode: OutputMode::Json,
            working_dir: "/tmp/project".to_owned(),
        };

        assert_eq!(
            format_text(&output),
            "flow 0.1.0\nautomated: true\noutput: json\nworking_dir: /tmp/project"
        );
    }

    #[test]
    fn serializes_doctor_output_stably() {
        let output = DoctorOutput {
            cli_name: "flow".to_owned(),
            version: "0.1.0".to_owned(),
            automated: false,
            output_mode: OutputMode::Text,
            working_dir: "/tmp/project".to_owned(),
        };

        assert_eq!(
            serde_json::to_string(&output).expect("json render succeeds"),
            "{\"cli_name\":\"flow\",\"version\":\"0.1.0\",\"automated\":false,\"output_mode\":\"text\",\"working_dir\":\"/tmp/project\"}"
        );
    }
}
