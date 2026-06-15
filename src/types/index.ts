export interface WatchedFolder {
  id: string;
  path: string;
  enabled: boolean;
  created_at: string;
}

export type ConditionMatch = "all" | "any";

export type ConditionKind =
  | "name"
  | "extension"
  | "kind"
  | "size_bytes"
  | "tags"
  | "color_label"
  | "contents";

export type Operator =
  | "is"
  | "is_not"
  | "contains"
  | "does_not_contain"
  | "starts_with"
  | "ends_with"
  | "matches_regex"
  | "greater_than"
  | "less_than";

export interface Condition {
  id: string;
  rule_id: string;
  kind: ConditionKind;
  operator: Operator;
  value: string;
}

export type ActionKind =
  | "move_to_folder"
  | "copy_to_folder"
  | "rename"
  | "move_to_trash"
  | "delete"
  | "add_tag"
  | "remove_tag"
  | "set_color_label"
  | "run_script";

export interface Action {
  id: string;
  rule_id: string;
  kind: ActionKind;
  params: Record<string, unknown>;
  position: number;
}

export interface Rule {
  id: string;
  folder_id: string;
  name: string;
  enabled: boolean;
  condition_match: ConditionMatch;
  conditions: Condition[];
  actions: Action[];
  priority: number;
  created_at: string;
}

export interface RulePreview {
  rule_id: string;
  rule_name: string;
  actions: string[];
}

export interface FilePreview {
  path: string;
  name: string;
  rules: RulePreview[];
}

export interface PreviewResult {
  files_scanned: number;
  matches: FilePreview[];
}

export interface UpdateInfo {
  current_version: string;
  latest_version: string;
  has_update: boolean;
  release_url: string;
  release_name: string;
}

export type UpdateStatus =
  | "idle"
  | "checking"
  | "up-to-date"
  | "available"
  | "installing"
  | "installed"
  | "error";

// Labels used in the UI
export const CONDITION_KIND_LABELS: Record<ConditionKind, string> = {
  name: "Name",
  extension: "Extension",
  kind: "Kind",
  size_bytes: "Size",
  tags: "Tags",
  color_label: "Color label",
  contents: "Contents",
};

export const OPERATOR_LABELS: Record<Operator, string> = {
  is: "is",
  is_not: "is not",
  contains: "contains",
  does_not_contain: "does not contain",
  starts_with: "starts with",
  ends_with: "ends with",
  matches_regex: "matches regex",
  greater_than: "greater than",
  less_than: "less than",
};

export const ACTION_KIND_LABELS: Record<ActionKind, string> = {
  move_to_folder: "Move to folder",
  copy_to_folder: "Copy to folder",
  rename: "Rename",
  move_to_trash: "Move to Trash",
  delete: "Delete",
  add_tag: "Add tag",
  remove_tag: "Remove tag",
  set_color_label: "Set color label",
  run_script: "Run script",
};
