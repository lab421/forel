use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WatchedFolder {
    pub id: String,
    pub path: String,
    pub enabled: bool,
    pub created_at: String,
}

impl WatchedFolder {
    pub fn new(path: String) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            path,
            enabled: true,
            created_at: chrono::Utc::now().to_rfc3339(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ConditionMatch {
    All,
    Any,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Rule {
    pub id: String,
    pub folder_id: String,
    pub name: String,
    pub enabled: bool,
    pub condition_match: ConditionMatch,
    pub recursion_depth: Option<i64>,
    pub conditions: Vec<Condition>,
    pub actions: Vec<Action>,
    pub priority: i64,
    pub created_at: String,
}

impl Rule {
    pub fn new(folder_id: String, name: String) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            folder_id,
            name,
            enabled: false,
            condition_match: ConditionMatch::All,
            recursion_depth: Some(0),
            conditions: vec![],
            actions: vec![],
            priority: 0,
            created_at: chrono::Utc::now().to_rfc3339(),
        }
    }
}

// ---------- Conditions ----------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ConditionKind {
    Name,
    Extension,
    Kind,
    SizeBytes,
    Tags,
    ColorLabel,
    Contents,
    CreatedAt,
    DateModified,
    DateAdded,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Operator {
    Is,
    IsNot,
    Contains,
    DoesNotContain,
    StartsWith,
    EndsWith,
    MatchesRegex,
    GreaterThan,
    LessThan,
    Before,
    After,
    OlderThan,
    WithinLast,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Condition {
    pub id: String,
    pub rule_id: String,
    pub kind: ConditionKind,
    pub operator: Operator,
    pub value: String,
}

// ---------- Actions ----------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    MoveToFolder,
    CopyToFolder,
    Rename,
    MoveToTrash,
    Delete,
    AddTag,
    RemoveTag,
    SetColorLabel,
    RunScript,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Action {
    pub id: String,
    pub rule_id: String,
    pub kind: ActionKind,
    /// JSON-encoded parameters specific to each action kind.
    /// e.g. `MoveToFolder`: {"destination": "/path/to/folder"}
    /// Rename: {"pattern": "{name} - {`date_modified`}"}
    /// `AddTag`: {"tag": "important"}
    pub params: serde_json::Value,
    pub position: i64,
}

// ---------- Action history ----------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HistoryStatus {
    Applied,
    Undone,
}

/// A single executed action, recorded so it can be reviewed (log) and reversed
/// (undo). Entries from one rule run share a `batch_id`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: String,
    pub batch_id: String,
    pub rule_id: Option<String>,
    pub rule_name: String,
    pub action_kind: ActionKind,
    pub original_path: String,
    pub result_path: String,
    /// Serialised `rules::action::Undo`.
    pub undo: serde_json::Value,
    pub reversible: bool,
    pub status: HistoryStatus,
    pub created_at: String,
}
