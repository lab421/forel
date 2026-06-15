use std::path::Path;

use anyhow::{bail, Context, Result};

use super::model::{Action, ActionKind};

/// Executes the action on the file at `path`.
pub fn execute(action: &Action, path: &Path) -> Result<()> {
    match &action.kind {
        ActionKind::MoveToFolder => {
            let dest_dir = action
                .params
                .get("destination")
                .and_then(|v| v.as_str())
                .context("MoveToFolder requires 'destination' param")?;
            let file_name = path.file_name().context("no file name")?;
            let dest = Path::new(dest_dir).join(file_name);
            std::fs::rename(path, &dest)
                .with_context(|| format!("move {} → {}", path.display(), dest.display()))?;
        },

        ActionKind::CopyToFolder => {
            let dest_dir = action
                .params
                .get("destination")
                .and_then(|v| v.as_str())
                .context("CopyToFolder requires 'destination' param")?;
            let file_name = path.file_name().context("no file name")?;
            let dest = Path::new(dest_dir).join(file_name);
            std::fs::copy(path, &dest)
                .with_context(|| format!("copy {} → {}", path.display(), dest.display()))?;
        },

        ActionKind::Rename => {
            let pattern = action
                .params
                .get("pattern")
                .and_then(|v| v.as_str())
                .context("Rename requires 'pattern' param")?;
            let new_name = apply_rename_pattern(pattern, path)?;
            let dest = path.with_file_name(new_name);
            std::fs::rename(path, &dest)
                .with_context(|| format!("rename {} → {}", path.display(), dest.display()))?;
        },

        ActionKind::MoveToTrash => {
            // On macOS, move to ~/.Trash
            let file_name = path.file_name().context("no file name")?;
            let trash = dirs_next()?;
            let dest = trash.join(file_name);
            std::fs::rename(path, &dest)?;
        },

        ActionKind::Delete => {
            if path.is_dir() {
                std::fs::remove_dir_all(path)?;
            } else {
                std::fs::remove_file(path)?;
            }
        },

        ActionKind::AddTag => {
            for tag in param_tags(action) {
                apply_file_tag(path, tag, true)?;
            }
        },

        ActionKind::RemoveTag => {
            for tag in param_tags(action) {
                apply_file_tag(path, tag, false)?;
            }
        },

        ActionKind::SetColorLabel => {
            let color = action
                .params
                .get("color")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            set_color_label(path, color)?;
        },

        ActionKind::RunScript => {
            let script = action
                .params
                .get("script")
                .and_then(|v| v.as_str())
                .context("RunScript requires 'script' param")?;
            std::process::Command::new("bash")
                .args(["-c", script])
                .env("FOREL_FILE", path)
                .spawn()?;
        },
    }

    Ok(())
}

pub fn preview(action: &Action, path: &Path) -> Result<String> {
    let file_name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");

    Ok(match &action.kind {
        ActionKind::MoveToFolder => {
            let dest_dir = action
                .params
                .get("destination")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            format!("Move to {}", Path::new(dest_dir).join(file_name).display())
        },
        ActionKind::CopyToFolder => {
            let dest_dir = action
                .params
                .get("destination")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            format!("Copy to {}", Path::new(dest_dir).join(file_name).display())
        },
        ActionKind::Rename => {
            let pattern = action
                .params
                .get("pattern")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let new_name = apply_rename_pattern(pattern, path)?;
            format!("Rename to {new_name}")
        },
        ActionKind::MoveToTrash => "Move to Trash".to_string(),
        ActionKind::Delete => "Delete permanently".to_string(),
        ActionKind::AddTag => {
            let tags = param_tags(action);
            if tags.is_empty() {
                "Add tag".to_string()
            } else if action.params.get("tag").is_some() && tags.len() == 1 {
                format!("Add tag '{}'", tags[0])
            } else {
                format!(
                    "Add tag{}: {}",
                    if tags.len() > 1 { "s" } else { "" },
                    tags.join(", ")
                )
            }
        },
        ActionKind::RemoveTag => {
            let tags = param_tags(action);
            if tags.is_empty() {
                "Remove tag".to_string()
            } else if action.params.get("tag").is_some() && tags.len() == 1 {
                format!("Remove tag '{}'", tags[0])
            } else {
                format!(
                    "Remove tag{}: {}",
                    if tags.len() > 1 { "s" } else { "" },
                    tags.join(", ")
                )
            }
        },
        ActionKind::SetColorLabel => {
            let color = action
                .params
                .get("color")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if color.is_empty() {
                "Clear color label".to_string()
            } else {
                format!("Set color label to {color}")
            }
        },
        ActionKind::RunScript => {
            let script = action
                .params
                .get("script")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let first_line = script.lines().next().unwrap_or("").trim();
            if first_line.is_empty() {
                "Run script".to_string()
            } else {
                format!("Run script: {first_line}")
            }
        },
    })
}

pub fn would_change(action: &Action, path: &Path) -> bool {
    match &action.kind {
        ActionKind::SetColorLabel => {
            let target = action
                .params
                .get("color")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_lowercase();
            current_color_name(path) != target
        },
        ActionKind::AddTag => {
            let existing = read_file_tags(path);
            param_tags(action)
                .iter()
                .any(|tag| !existing.iter().any(|existing_tag| existing_tag == tag))
        },
        ActionKind::RemoveTag => {
            let existing = read_file_tags(path);
            param_tags(action)
                .iter()
                .any(|tag| existing.iter().any(|existing_tag| existing_tag == tag))
        },
        ActionKind::Rename => {
            let pattern = action
                .params
                .get("pattern")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            apply_rename_pattern(pattern, path).map_or(true, |new_name| {
                path.file_name()
                    .and_then(|s| s.to_str())
                    .is_none_or(|current_name| current_name != new_name)
            })
        },
        ActionKind::MoveToFolder
        | ActionKind::CopyToFolder
        | ActionKind::MoveToTrash
        | ActionKind::Delete
        | ActionKind::RunScript => true,
    }
}

fn param_tags(action: &Action) -> Vec<&str> {
    if let Some(tags) = action.params.get("tags").and_then(|v| v.as_array()) {
        return tags.iter().filter_map(|v| v.as_str()).collect();
    }

    action
        .params
        .get("tag")
        .and_then(|v| v.as_str())
        .into_iter()
        .collect()
}

// Precision loss is intentional: we only show one decimal place.
#[allow(clippy::cast_precision_loss)]
fn format_file_size(bytes: u64) -> String {
    const KB: u64 = 1_024;
    const MB: u64 = 1_024 * KB;
    const GB: u64 = 1_024 * MB;
    if bytes >= GB {
        format!("{:.1}GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1}MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1}KB", bytes as f64 / KB as f64)
    } else {
        format!("{bytes}B")
    }
}

/// Substitutes tokens in rename patterns.
/// Supported tokens: `{name}`, `{extension}`, `{date_created}`, `{date_modified}`, `{current_date}`, `{size}`
fn apply_rename_pattern(pattern: &str, path: &Path) -> Result<String> {
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");

    let meta = std::fs::metadata(path)?;
    let modified: chrono::DateTime<chrono::Local> = meta.modified()?.into();
    let created: chrono::DateTime<chrono::Local> = meta.created()?.into();
    let today = chrono::Local::now();
    let size_str = format_file_size(meta.len());

    let result = pattern
        .replace("{name}", stem)
        .replace("{extension}", ext)
        .replace("{date_modified}", &modified.format("%Y-%m-%d").to_string())
        .replace("{date_created}", &created.format("%Y-%m-%d").to_string())
        .replace("{current_date}", &today.format("%Y-%m-%d").to_string())
        .replace("{size}", &size_str);

    if result.is_empty() {
        bail!("rename pattern produced empty filename");
    }

    if ext.is_empty() || pattern.contains("{extension}") {
        Ok(result)
    } else {
        Ok(format!("{result}.{ext}"))
    }
}

#[cfg(target_os = "macos")]
fn dirs_next() -> Result<std::path::PathBuf> {
    let home = std::env::var("HOME").context("HOME not set")?;
    Ok(std::path::PathBuf::from(home).join(".Trash"))
}

#[cfg(not(target_os = "macos"))]
fn dirs_next() -> Result<std::path::PathBuf> {
    bail!("trash is only implemented on macOS")
}

// ---------- macOS Finder tags via xattr ----------

const TAGS_XATTR: &str = "com.apple.metadata:_kMDItemUserTags";

/// Reads the Finder tags on `path`, or an empty list if there are none.
///
/// Tags are stored as a binary-plist–encoded `Vec<String>` in the extended
/// attribute `com.apple.metadata:_kMDItemUserTags`. A color label is just a
/// tag whose name matches a system colour (sometimes suffixed with "\nN").
pub fn read_file_tags(path: &Path) -> Vec<String> {
    xattr::get(path, TAGS_XATTR)
        .ok()
        .flatten()
        .and_then(|bytes| plist::from_bytes::<Vec<String>>(&bytes).ok())
        .unwrap_or_default()
}

/// Serialises `tags` to a binary plist and writes them to the xattr.
fn write_file_tags(path: &Path, tags: &[String]) -> Result<()> {
    let mut buf: Vec<u8> = Vec::new();
    plist::to_writer_binary(std::io::Cursor::new(&mut buf), &tags)
        .context("failed to serialise tags plist")?;
    xattr::set(path, TAGS_XATTR, &buf).context("failed to write tags xattr")?;
    Ok(())
}

/// Adds or removes a named Finder tag on `path`. Finder reads tags live so the
/// change is visible immediately without any Finder restart.
fn apply_file_tag(path: &Path, tag: &str, add: bool) -> Result<()> {
    let mut tags = read_file_tags(path);

    if add {
        if !tags.iter().any(|t| t == tag) {
            tags.push(tag.to_string());
        }
    } else {
        tags.retain(|t| t != tag);
    }

    write_file_tags(path, &tags)
}

/// Finder colour-label index for each of the 7 system colours.
fn color_index(name: &str) -> Option<u8> {
    match name.to_lowercase().as_str() {
        "gray" | "grey" => Some(1),
        "green" => Some(2),
        "purple" => Some(3),
        "blue" => Some(4),
        "yellow" => Some(5),
        "red" => Some(6),
        "orange" => Some(7),
        _ => None,
    }
}

fn current_color_name(path: &Path) -> String {
    read_file_tags(path)
        .into_iter()
        .find_map(|tag| {
            let name = tag.split('\n').next().unwrap_or(&tag).trim();
            color_index(name).map(|_| name.to_lowercase())
        })
        .unwrap_or_default()
}

/// Sets the macOS colour label on `path`, replacing any existing colour label.
///
/// Finder stores a colour label as a tag of the form `"Name\nIndex"`. We drop
/// any existing system-colour tag first so a file has at most one colour, then
/// add the new one. An empty/`"none"` colour just clears the label.
fn set_color_label(path: &Path, color: &str) -> Result<()> {
    let mut tags = read_file_tags(path);

    // Remove any existing colour-label tag (a tag whose name is a system colour).
    tags.retain(|t| {
        let name = t.split('\n').next().unwrap_or(t).trim();
        color_index(name).is_none()
    });

    if let Some(idx) = color_index(color) {
        tags.push(format!("{}\n{}", capitalize(color), idx));
    }

    write_file_tags(path, &tags)
}

fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use serde_json::json;
    use uuid::Uuid;

    use super::*;

    struct TestDir {
        path: PathBuf,
    }

    impl TestDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("forel-action-test-{}", Uuid::new_v4()));
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
    fn add_and_remove_tag_updates_finder_tag_xattr_without_duplicates() {
        let dir = TestDir::new();
        let file = dir.file("document.txt", "hello");
        let add = test_action(ActionKind::AddTag, json!({ "tags": ["Project"] }));
        let remove = test_action(ActionKind::RemoveTag, json!({ "tags": ["Project"] }));

        execute(&add, &file).expect("add tag once");
        execute(&add, &file).expect("add tag twice");
        assert_eq!(read_file_tags(&file), vec!["Project".to_string()]);

        execute(&remove, &file).expect("remove tag");
        assert!(read_file_tags(&file).is_empty());
    }

    #[test]
    fn set_color_label_replaces_existing_color_and_preserves_text_tags() {
        let dir = TestDir::new();
        let file = dir.file("image.png", "png");
        let add_text_tag = test_action(ActionKind::AddTag, json!({ "tags": ["Project"] }));
        let set_red = test_action(ActionKind::SetColorLabel, json!({ "color": "Red" }));
        let set_blue = test_action(ActionKind::SetColorLabel, json!({ "color": "Blue" }));

        execute(&add_text_tag, &file).expect("add text tag");
        execute(&set_red, &file).expect("set red label");
        execute(&set_blue, &file).expect("replace with blue label");

        assert_eq!(
            read_file_tags(&file),
            vec!["Project".to_string(), "Blue\n4".to_string()]
        );
    }

    #[test]
    fn set_color_label_with_missing_color_clears_existing_label() {
        let dir = TestDir::new();
        let file = dir.file("image.png", "png");
        let add_text_tag = test_action(ActionKind::AddTag, json!({ "tags": ["Project"] }));
        let set_red = test_action(ActionKind::SetColorLabel, json!({ "color": "Red" }));
        let clear = test_action(ActionKind::SetColorLabel, json!({}));

        execute(&add_text_tag, &file).expect("add text tag");
        execute(&set_red, &file).expect("set red label");
        execute(&clear, &file).expect("clear label");

        assert_eq!(read_file_tags(&file), vec!["Project".to_string()]);
    }

    #[test]
    fn rename_pattern_does_not_append_extension_twice_when_extension_token_is_used() {
        let dir = TestDir::new();
        let file = dir.file("report.txt", "hello");
        let rename = test_action(
            ActionKind::Rename,
            json!({ "pattern": "{name}-archived.{extension}" }),
        );

        execute(&rename, &file).expect("rename file");

        assert!(!file.exists());
        assert!(dir.path.join("report-archived.txt").exists());
        assert!(!dir.path.join("report-archived.txt.txt").exists());
    }
}
