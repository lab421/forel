use std::path::Path;

use anyhow::Result;

use super::model::{Condition, ConditionKind, Operator};

/// Returns true if the file at `path` satisfies the condition.
pub fn evaluate(condition: &Condition, path: &Path) -> Result<bool> {
    let meta = std::fs::metadata(path)?;

    match &condition.kind {
        ConditionKind::Name => {
            let name = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
            Ok(match_string(&condition.operator, name, &condition.value))
        }

        ConditionKind::Extension => {
            let ext = path
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_lowercase();
            let value = condition.value.trim_start_matches('.').to_lowercase();
            Ok(match_string(&condition.operator, &ext, &value))
        }

        ConditionKind::Kind => {
            let detected = detect_kind(path, &meta);
            Ok(match condition.operator {
                Operator::Is => detected == condition.value,
                Operator::IsNot => detected != condition.value,
                _ => false,
            })
        }

        ConditionKind::SizeBytes => {
            let size = meta.len();
            let threshold = parse_size(&condition.value);
            Ok(match condition.operator {
                Operator::Is => size == threshold,
                Operator::IsNot => size != threshold,
                Operator::GreaterThan => size > threshold,
                Operator::LessThan => size < threshold,
                _ => false,
            })
        }

        ConditionKind::Tags => {
            let target = condition.value.trim().to_lowercase();
            // Tag names only (drop the "\nN" colour-index suffix if present).
            let names: Vec<String> = super::action::read_file_tags(path)
                .iter()
                .map(|t| t.split('\n').next().unwrap_or(t).trim().to_lowercase())
                .collect();
            Ok(match condition.operator {
                Operator::Is => names.iter().any(|n| *n == target),
                Operator::IsNot => !names.iter().any(|n| *n == target),
                Operator::Contains => names.iter().any(|n| n.contains(target.as_str())),
                Operator::DoesNotContain => !names.iter().any(|n| n.contains(target.as_str())),
                Operator::StartsWith => names.iter().any(|n| n.starts_with(target.as_str())),
                Operator::EndsWith => names.iter().any(|n| n.ends_with(target.as_str())),
                Operator::MatchesRegex => regex::Regex::new(&condition.value)
                    .map(|re| names.iter().any(|n| re.is_match(n)))
                    .unwrap_or(false),
                _ => false,
            })
        }

        ConditionKind::ColorLabel => {
            let target = condition.value.to_lowercase();
            let has = super::action::read_file_tags(path).iter().any(|tag| {
                // A label may be stored as "Red\n6" — compare the name part only.
                let name = tag.split('\n').next().unwrap_or(tag).trim().to_lowercase();
                name == target
            });
            Ok(match condition.operator {
                Operator::Is => has,
                Operator::IsNot => !has,
                _ => false,
            })
        }

        ConditionKind::Contents => {
            let text = std::fs::read_to_string(path).unwrap_or_default();
            Ok(match_string(&condition.operator, &text, &condition.value))
        }
    }
}

/// Classifies a file into a Hazel-style kind string based on its extension.
fn detect_kind(path: &Path, meta: &std::fs::Metadata) -> &'static str {
    if meta.is_dir() {
        return if path.extension().and_then(|e| e.to_str()) == Some("app") {
            "application"
        } else {
            "folder"
        };
    }

    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase());

    match ext.as_deref() {
        Some(
            "jpg" | "jpeg" | "png" | "gif" | "bmp" | "tiff" | "tif" | "webp" | "svg" | "heic"
            | "heif" | "raw" | "cr2" | "cr3" | "nef" | "arw" | "dng",
        ) => "image",

        Some("mp4" | "mov" | "avi" | "mkv" | "m4v" | "wmv" | "flv" | "webm" | "mpg" | "mpeg") => {
            "movie"
        }

        Some("mp3" | "aac" | "flac" | "wav" | "aiff" | "aif" | "m4a" | "ogg" | "wma" | "opus") => {
            "music"
        }

        Some("pdf") => "pdf",

        Some("txt" | "md" | "markdown" | "rtf" | "rst" | "log") => "text",

        Some("ppt" | "pptx" | "key" | "odp") => "presentation",

        Some(
            "zip" | "tar" | "gz" | "bz2" | "7z" | "rar" | "xz" | "zst" | "tgz" | "tbz" | "cab",
        ) => "archive",

        Some("dmg" | "iso" | "img" | "sparseimage" | "sparsebundle") => "disk_image",

        Some(
            "doc" | "docx" | "odt" | "pages" | "xls" | "xlsx" | "ods" | "numbers" | "csv" | "epub",
        ) => "document",

        _ => "document",
    }
}

fn match_string(operator: &Operator, haystack: &str, needle: &str) -> bool {
    match operator {
        Operator::Is => haystack == needle,
        Operator::IsNot => haystack != needle,
        Operator::Contains => haystack.contains(needle),
        Operator::DoesNotContain => !haystack.contains(needle),
        Operator::StartsWith => haystack.starts_with(needle),
        Operator::EndsWith => haystack.ends_with(needle),
        Operator::MatchesRegex => regex::Regex::new(needle)
            .map(|re| re.is_match(haystack))
            .unwrap_or(false),
        _ => false,
    }
}

/// Parses a size threshold into bytes. Accepts a plain number ("5242880") or a
/// number with a unit suffix ("5 MB", "100kb"). Unitless values are bytes.
fn parse_size(value: &str) -> u64 {
    let s = value.trim();
    let split = s
        .find(|c: char| !c.is_ascii_digit() && c != '.')
        .unwrap_or(s.len());
    let (num, unit) = s.split_at(split);
    let n: f64 = num.trim().parse().unwrap_or(0.0);
    let mult = match unit.trim().to_lowercase().as_str() {
        "kb" => 1024.0,
        "mb" => 1024.0 * 1024.0,
        "gb" => 1024.0 * 1024.0 * 1024.0,
        _ => 1.0,
    };
    (n * mult) as u64
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use serde_json::json;
    use uuid::Uuid;

    use super::*;
    use crate::rules::{
        action,
        model::{Action, ActionKind},
    };

    struct TestDir {
        path: PathBuf,
    }

    impl TestDir {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("forel-condition-test-{}", Uuid::new_v4()));
            fs::create_dir(&path).expect("create temp test directory");
            Self { path }
        }

        fn file(&self, name: &str, contents: &str) -> PathBuf {
            let path = self.path.join(name);
            fs::write(&path, contents).expect("write temp test file");
            path
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn condition(kind: ConditionKind, operator: Operator, value: &str) -> Condition {
        Condition {
            id: Uuid::new_v4().to_string(),
            rule_id: "rule".to_string(),
            kind,
            operator,
            value: value.to_string(),
        }
    }

    fn test_action(kind: ActionKind, params: serde_json::Value) -> Action {
        Action {
            id: Uuid::new_v4().to_string(),
            rule_id: "rule".to_string(),
            kind,
            params,
            position: 0,
        }
    }

    #[test]
    fn parse_size_supports_bytes_and_binary_units() {
        assert_eq!(parse_size("1024"), 1024);
        assert_eq!(parse_size("1 KB"), 1024);
        assert_eq!(parse_size("1.5 MB"), 1_572_864);
        assert_eq!(parse_size("2GB"), 2_147_483_648);
        assert_eq!(parse_size("bad value"), 0);
    }

    #[test]
    fn size_condition_compares_parsed_thresholds() {
        let dir = TestDir::new();
        let file = dir.file("data.bin", "1234567890");

        assert!(evaluate(
            &condition(ConditionKind::SizeBytes, Operator::Is, "10 bytes"),
            &file
        )
        .expect("evaluate size is"));
        assert!(evaluate(
            &condition(ConditionKind::SizeBytes, Operator::LessThan, "1 KB"),
            &file
        )
        .expect("evaluate size less than"));
    }

    #[test]
    fn tag_condition_matches_trimmed_case_insensitive_tag_names() {
        let dir = TestDir::new();
        let file = dir.file("document.txt", "hello");
        let add_tag = test_action(ActionKind::AddTag, json!({ "tag": "Project" }));

        action::execute(&add_tag, &file).expect("add tag");

        assert!(evaluate(
            &condition(ConditionKind::Tags, Operator::Is, " project "),
            &file
        )
        .expect("evaluate tag equality"));
        assert!(evaluate(
            &condition(ConditionKind::Tags, Operator::Contains, "roj"),
            &file
        )
        .expect("evaluate tag contains"));
        assert!(evaluate(
            &condition(ConditionKind::Tags, Operator::MatchesRegex, "^proj"),
            &file
        )
        .expect("evaluate tag regex"));
    }

    #[test]
    fn color_label_condition_matches_finder_color_tag_name() {
        let dir = TestDir::new();
        let file = dir.file("image.png", "png");
        let set_red = test_action(ActionKind::SetColorLabel, json!({ "color": "Red" }));

        action::execute(&set_red, &file).expect("set color label");

        assert!(evaluate(
            &condition(ConditionKind::ColorLabel, Operator::Is, "red"),
            &file
        )
        .expect("evaluate red label"));
        assert!(evaluate(
            &condition(ConditionKind::ColorLabel, Operator::IsNot, "blue"),
            &file
        )
        .expect("evaluate missing blue label"));
    }

    #[test]
    fn kind_condition_classifies_common_file_types_and_directories() {
        let dir = TestDir::new();
        let pdf = dir.file("paper.pdf", "%PDF");
        let image = dir.file("photo.heic", "image");
        let archive = dir.file("backup.tar", "archive");
        let folder = dir.path.join("Folder");
        fs::create_dir(&folder).expect("create folder");
        let app = dir.path.join("Example.app");
        fs::create_dir(&app).expect("create app bundle");

        assert!(
            evaluate(&condition(ConditionKind::Kind, Operator::Is, "pdf"), &pdf)
                .expect("evaluate pdf kind")
        );
        assert!(evaluate(
            &condition(ConditionKind::Kind, Operator::Is, "image"),
            &image
        )
        .expect("evaluate image kind"));
        assert!(evaluate(
            &condition(ConditionKind::Kind, Operator::Is, "archive"),
            &archive
        )
        .expect("evaluate archive kind"));
        assert!(evaluate(
            &condition(ConditionKind::Kind, Operator::Is, "folder"),
            &folder
        )
        .expect("evaluate folder kind"));
        assert!(evaluate(
            &condition(ConditionKind::Kind, Operator::Is, "application"),
            &app
        )
        .expect("evaluate application kind"));
    }
}
