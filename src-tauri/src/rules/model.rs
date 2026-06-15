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
