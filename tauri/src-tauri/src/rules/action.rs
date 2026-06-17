use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use super::model::{Action, ActionKind};

/// Outcome of executing an action: where the file ended up, plus the
/// information needed to reverse the change later.
pub struct Applied {
    pub new_path: PathBuf,
    pub undo: Undo,
}

/// Reversal recipe for an executed action. Serialised to JSON and stored in the
/// action history so the change can be undone after the fact.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Undo {
    /// File was relocated; undo by moving `to` back to `from`.
    Move { from: PathBuf, to: PathBuf },
    /// A copy was created; undo by deleting it.
    Copy { copy: PathBuf },
    /// Tags were added; undo by removing exactly these.
    AddTags { path: PathBuf, tags: Vec<String> },
    /// Tags were removed; undo by re-adding exactly these.
    RemoveTags { path: PathBuf, tags: Vec<String> },
    /// Colour label changed; undo by restoring `previous` ("" = none).
    Color { path: PathBuf, previous: String },
    /// Not reversible (e.g. a script with arbitrary side effects).
    None,
}

impl Undo {
    pub fn is_reversible(&self) -> bool {
        !matches!(self, Undo::None)
    }
}

/// Executes the action on the file at `path`, returning the new path and an
/// [`Undo`] describing how to reverse it.
pub fn execute(action: &Action, path: &Path) -> Result<Applied> {
    match &action.kind {
        ActionKind::MoveToFolder => {
            let dest_dir = str_param(action, "destination", "MoveToFolder")?;
            move_into_dir(path, Path::new(dest_dir))
        },
        ActionKind::CopyToFolder => copy_to_folder(action, path),
        ActionKind::Rename => rename_file(action, path),
        // Delete is routed through the Trash so it stays reversible.
        ActionKind::MoveToTrash | ActionKind::Delete => move_into_dir(path, &trash_dir()?),
        ActionKind::AddTag => apply_tags(action, path, true),
        ActionKind::RemoveTag => apply_tags(action, path, false),
        ActionKind::SetColorLabel => set_color(action, path),
        ActionKind::RunScript => run_script(action, path),
    }
}

fn str_param<'a>(action: &'a Action, key: &str, kind: &str) -> Result<&'a str> {
    action
        .params
        .get(key)
        .and_then(|v| v.as_str())
        .with_context(|| format!("{kind} requires '{key}' param"))
}

/// Moves `path` into `dest_dir` (created if needed), avoiding name collisions.
fn move_into_dir(path: &Path, dest_dir: &Path) -> Result<Applied> {
    std::fs::create_dir_all(dest_dir)
        .with_context(|| format!("create destination dir {}", dest_dir.display()))?;
    let file_name = path.file_name().context("no file name")?;
    let dest = unique_dest(dest_dir, file_name);
    std::fs::rename(path, &dest)
        .with_context(|| format!("move {} → {}", path.display(), dest.display()))?;
    Ok(Applied {
        new_path: dest.clone(),
        undo: Undo::Move {
            from: path.to_path_buf(),
            to: dest,
        },
    })
}

fn copy_to_folder(action: &Action, path: &Path) -> Result<Applied> {
    let dest_dir = Path::new(str_param(action, "destination", "CopyToFolder")?);
    std::fs::create_dir_all(dest_dir)
        .with_context(|| format!("create destination dir {}", dest_dir.display()))?;
    let file_name = path.file_name().context("no file name")?;
    let dest = unique_dest(dest_dir, file_name);
    std::fs::copy(path, &dest)
        .with_context(|| format!("copy {} → {}", path.display(), dest.display()))?;
    Ok(Applied {
        new_path: path.to_path_buf(),
        undo: Undo::Copy { copy: dest },
    })
}

fn rename_file(action: &Action, path: &Path) -> Result<Applied> {
    let pattern = str_param(action, "pattern", "Rename")?;
    let new_name = apply_rename_pattern(pattern, path)?;
    let dest = path.with_file_name(new_name);
    std::fs::rename(path, &dest)
        .with_context(|| format!("rename {} → {}", path.display(), dest.display()))?;
    Ok(Applied {
        new_path: dest.clone(),
        undo: Undo::Move {
            from: path.to_path_buf(),
            to: dest,
        },
    })
}

/// Adds (`add = true`) or removes Finder tags, capturing exactly the tags that
/// actually changed so the undo only touches those.
fn apply_tags(action: &Action, path: &Path, add: bool) -> Result<Applied> {
    let existing = read_file_tags(path);
    let mut changed: Vec<String> = Vec::new();
    for tag in param_tags(action) {
        let present = existing.iter().any(|t| t == tag);
        if present != add && !changed.iter().any(|t| t == tag) {
            changed.push(tag.to_string());
        }
        apply_file_tag(path, tag, add)?;
    }
    let undo = if add {
        Undo::AddTags {
            path: path.to_path_buf(),
            tags: changed,
        }
    } else {
        Undo::RemoveTags {
            path: path.to_path_buf(),
            tags: changed,
        }
    };
    Ok(Applied {
        new_path: path.to_path_buf(),
        undo,
    })
}

fn set_color(action: &Action, path: &Path) -> Result<Applied> {
    let color = action
        .params
        .get("color")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let previous = current_color_name(path);
    set_color_label(path, color)?;
    Ok(Applied {
        new_path: path.to_path_buf(),
        undo: Undo::Color {
            path: path.to_path_buf(),
            previous,
        },
    })
}

fn run_script(action: &Action, path: &Path) -> Result<Applied> {
    let script = str_param(action, "script", "RunScript")?;
    let status = std::process::Command::new("bash")
        .args(["-c", script])
        .env("FOREL_FILE", path)
        .status()
        .context("failed to launch bash")?;
    if !status.success() {
        bail!("script exited with status {status}");
    }
    Ok(Applied {
        new_path: path.to_path_buf(),
        undo: Undo::None,
    })
}

/// Reverses a previously executed action using its stored [`Undo`].
pub fn revert(undo: &Undo) -> Result<()> {
    match undo {
        Undo::Move { from, to } => {
            if from.exists() {
                bail!(
                    "cannot restore {}: a file already exists there",
                    from.display()
                );
            }
            if let Some(parent) = from.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("recreate parent {}", parent.display()))?;
            }
            std::fs::rename(to, from)
                .with_context(|| format!("restore {} → {}", to.display(), from.display()))?;
            Ok(())
        },
        Undo::Copy { copy } => {
            if copy.exists() {
                if copy.is_dir() {
                    std::fs::remove_dir_all(copy)?;
                } else {
                    std::fs::remove_file(copy)?;
                }
            }
            Ok(())
        },
        Undo::AddTags { path, tags } => {
            for tag in tags {
                apply_file_tag(path, tag, false)?;
            }
            Ok(())
        },
        Undo::RemoveTags { path, tags } => {
            for tag in tags {
                apply_file_tag(path, tag, true)?;
            }
            Ok(())
        },
        Undo::Color { path, previous } => set_color_label(path, previous),
        Undo::None => bail!("this action cannot be undone"),
    }
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
        ActionKind::Delete => "Delete (move to Trash)".to_string(),
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

    // Append the original extension only when the pattern did not place it
    // explicitly (via the {extension} token or by typing it literally).
    let already_has_ext = result
        .to_lowercase()
        .ends_with(&format!(".{}", ext.to_lowercase()));
    if ext.is_empty() || pattern.contains("{extension}") || already_has_ext {
        Ok(result)
    } else {
        Ok(format!("{result}.{ext}"))
    }
}

/// Returns a destination path that does not yet exist, appending ` (N)` to the
/// stem when the intended name is already taken.
fn unique_dest(dir: &Path, file_name: &std::ffi::OsStr) -> PathBuf {
    let candidate = dir.join(file_name);
    if !candidate.exists() {
        return candidate;
    }
    let stem = Path::new(file_name)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let ext = Path::new(file_name).extension().and_then(|s| s.to_str());
    for i in 1u64.. {
        let new_name = match ext {
            Some(e) => format!("{stem} ({i}).{e}"),
            None => format!("{stem} ({i})"),
        };
        let candidate = dir.join(&new_name);
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(file_name)
}

#[cfg(target_os = "macos")]
fn trash_dir() -> Result<PathBuf> {
    let home = std::env::var("HOME").context("HOME not set")?;
    Ok(PathBuf::from(home).join(".Trash"))
}

#[cfg(not(target_os = "macos"))]
fn trash_dir() -> Result<PathBuf> {
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

    #[test]
    fn revert_move_restores_file_to_original_location() {
        let dir = TestDir::new();
        let file = dir.file("note.txt", "hello");
        let dest = dir.path.join("Archive");
        let move_action = test_action(
            ActionKind::MoveToFolder,
            json!({ "destination": dest.to_string_lossy() }),
        );

        let applied = execute(&move_action, &file).expect("move file");
        assert!(!file.exists());
        assert!(applied.new_path.exists());

        revert(&applied.undo).expect("undo move");
        assert!(file.exists());
        assert!(!applied.new_path.exists());
    }

    #[test]
    fn revert_rename_restores_original_name() {
        let dir = TestDir::new();
        let file = dir.file("report.txt", "hi");
        let rename = test_action(ActionKind::Rename, json!({ "pattern": "renamed" }));

        let applied = execute(&rename, &file).expect("rename");
        assert!(!file.exists());
        assert!(dir.path.join("renamed.txt").exists());

        revert(&applied.undo).expect("undo rename");
        assert!(file.exists());
        assert!(!dir.path.join("renamed.txt").exists());
    }

    #[test]
    fn revert_copy_deletes_the_created_copy() {
        let dir = TestDir::new();
        let file = dir.file("data.bin", "x");
        let dest = dir.path.join("Backup");
        let copy_action = test_action(
            ActionKind::CopyToFolder,
            json!({ "destination": dest.to_string_lossy() }),
        );

        let applied = execute(&copy_action, &file).expect("copy file");
        assert!(file.exists());
        assert!(dest.join("data.bin").exists());

        revert(&applied.undo).expect("undo copy");
        assert!(file.exists());
        assert!(!dest.join("data.bin").exists());
    }

    #[test]
    fn revert_add_tag_only_removes_newly_added_tags() {
        let dir = TestDir::new();
        let file = dir.file("doc.txt", "x");
        execute(
            &test_action(ActionKind::AddTag, json!({ "tags": ["Existing"] })),
            &file,
        )
        .expect("seed existing tag");

        let add = test_action(ActionKind::AddTag, json!({ "tags": ["Existing", "Fresh"] }));
        let applied = execute(&add, &file).expect("add tags");
        assert_eq!(
            read_file_tags(&file),
            vec!["Existing".to_string(), "Fresh".to_string()]
        );

        revert(&applied.undo).expect("undo add tag");
        // Only the genuinely-new "Fresh" tag is removed; "Existing" is preserved.
        assert_eq!(read_file_tags(&file), vec!["Existing".to_string()]);
    }

    #[test]
    fn revert_remove_tag_restores_removed_tags() {
        let dir = TestDir::new();
        let file = dir.file("doc.txt", "x");
        execute(
            &test_action(ActionKind::AddTag, json!({ "tags": ["Keep"] })),
            &file,
        )
        .expect("seed tag");

        let remove = test_action(ActionKind::RemoveTag, json!({ "tags": ["Keep"] }));
        let applied = execute(&remove, &file).expect("remove tag");
        assert!(read_file_tags(&file).is_empty());

        revert(&applied.undo).expect("undo remove tag");
        assert_eq!(read_file_tags(&file), vec!["Keep".to_string()]);
    }

    #[test]
    fn revert_color_label_restores_previous_color() {
        let dir = TestDir::new();
        let file = dir.file("image.png", "png");
        execute(
            &test_action(ActionKind::SetColorLabel, json!({ "color": "Red" })),
            &file,
        )
        .expect("set initial red");

        let set_blue = test_action(ActionKind::SetColorLabel, json!({ "color": "Blue" }));
        let applied = execute(&set_blue, &file).expect("set blue");
        assert_eq!(read_file_tags(&file), vec!["Blue\n4".to_string()]);

        revert(&applied.undo).expect("undo color");
        assert_eq!(read_file_tags(&file), vec!["Red\n6".to_string()]);
    }

    #[test]
    fn revert_run_script_is_rejected_as_irreversible() {
        let dir = TestDir::new();
        let file = dir.file("x.txt", "x");
        let script = test_action(ActionKind::RunScript, json!({ "script": "true" }));
        let applied = execute(&script, &file).expect("run script");
        assert!(!applied.undo.is_reversible());
        assert!(revert(&applied.undo).is_err());
    }
}
