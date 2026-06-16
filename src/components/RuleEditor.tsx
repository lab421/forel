import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { Minus, Plus, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useForelStore } from "../store";
import {
  ACTION_KIND_LABELS,
  Action,
  ActionKind,
  CONDITION_KIND_LABELS,
  Condition,
  ConditionKind,
  ConditionMatch,
  OPERATOR_LABELS,
  Operator,
  Rule,
} from "../types";
import { v4 as uuidv4 } from "uuid";
import { ColorDotPicker, COLOR_LABELS } from "./ui/ColorDotPicker";
import { TagsInput } from "./ui/TagsInput";

// Token definitions for the rename pattern editor
const RENAME_TOKENS: { key: string; label: string; example: string }[] = [
  { key: "name",          label: "name",          example: "document"    },
  { key: "extension",     label: "extension",     example: "pdf"         },
  { key: "date_modified", label: "date modified",  example: "2026-06-14" },
  { key: "date_created",  label: "date created",   example: "2026-01-01" },
  { key: "current_date",  label: "current date",   example: "2026-06-14" },
  { key: "size",          label: "size",           example: "1.4MB"      },
];

interface Props {
  rule: Rule;
  autoFocusTitle?: boolean;
  onClose: () => void;
  onSaved?: () => void;
}

const STRING_OPERATORS: Operator[] = [
  "is", "is_not", "contains", "does_not_contain",
  "starts_with", "ends_with", "matches_regex",
];
const NUMBER_OPERATORS: Operator[] = ["is", "is_not", "greater_than", "less_than"];
const PRESENCE_OPERATORS: Operator[] = ["is", "is_not"];
const DATE_OPERATORS: Operator[] = ["before", "after", "older_than", "within_last"];

// Condition kinds whose value is a date. They all share DATE_OPERATORS and the
// DateValue editor — adding a new date condition only needs an entry here.
const DATE_CONDITION_KINDS: ConditionKind[] = [
  "created_at",
  "date_modified",
  "date_added",
];
const DURATION_UNITS = ["days", "weeks", "months", "years"] as const;

const KIND_OPTIONS: { value: string; label: string }[] = [
  { value: "image",        label: "Image" },
  { value: "movie",        label: "Movie" },
  { value: "music",        label: "Music" },
  { value: "pdf",          label: "PDF" },
  { value: "text",         label: "Text" },
  { value: "document",     label: "Document" },
  { value: "presentation", label: "Presentation" },
  { value: "archive",      label: "Archive" },
  { value: "disk_image",   label: "Disk Image" },
  { value: "folder",       label: "Folder" },
  { value: "application",  label: "Application" },
];

const SIZE_UNITS = ["bytes", "KB", "MB", "GB"] as const;

const TERMINAL_ACTION_KINDS: ActionKind[] = [
  "move_to_folder",
  "move_to_trash",
  "delete",
];

function actionTags(actions: Action[], kind: ActionKind): Set<string> {
  return new Set(
    actions
      .filter((a) => a.kind === kind)
      .flatMap((a) => (Array.isArray(a.params.tags) ? (a.params.tags as string[]) : [])),
  );
}

function validateRule(rule: Rule): string | null {
  if (rule.actions.filter((a) => a.kind === "set_color_label").length > 1) {
    return "A rule can set only one color label.";
  }

  if (rule.actions.filter((a) => TERMINAL_ACTION_KINDS.includes(a.kind)).length > 1) {
    return "A rule can only move, trash, or delete a file once — these actions are mutually exclusive.";
  }

  const added = actionTags(rule.actions, "add_tag");
  const removed = actionTags(rule.actions, "remove_tag");
  const conflictTag = [...added].find((tag) => removed.has(tag));
  if (conflictTag) {
    return `Tag "${conflictTag}" is both added and removed by this rule.`;
  }

  for (const action of rule.actions) {
    if (
      (action.kind === "move_to_folder" || action.kind === "copy_to_folder") &&
      !action.params.destination
    ) {
      return "A folder action requires a destination path.";
    }
    if (action.kind === "rename" && !action.params.pattern) {
      return "A rename action requires a pattern.";
    }
    if (action.kind === "run_script" && !action.params.script) {
      return "A script action requires a script.";
    }
  }

  return null;
}

function scopeLabel(depth: number | null) {
  if (depth === null) return "All subfolders";
  if (depth === 0) return "Current folder";
  if (depth === 1) return "1 subfolder level";
  return `${depth} subfolder levels`;
}

function operatorsFor(kind: ConditionKind): Operator[] {
  if (kind === "size_bytes") return NUMBER_OPERATORS;
  if (kind === "kind" || kind === "color_label") return PRESENCE_OPERATORS;
  if (DATE_CONDITION_KINDS.includes(kind)) return DATE_OPERATORS;
  return STRING_OPERATORS;
}

export default function RuleEditor({ rule, autoFocusTitle = false, onClose, onSaved }: Props) {
  const { updateRule } = useForelStore();
  const [draft, setDraft] = useState<Rule>(structuredClone(rule));
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const titleInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (autoFocusTitle) titleInputRef.current?.focus();
  }, [autoFocusTitle]);

  const save = async () => {
    const problem = validateRule(draft);
    if (problem) {
      setError(problem);
      return;
    }

    setError(null);
    setSaving(true);
    try {
      await updateRule(draft);
      onSaved?.();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to save rule.");
    } finally {
      setSaving(false);
    }
  };

  const isCurrentFolder = draft.recursion_depth === 0;
  const isInfinite = draft.recursion_depth === null;

  const addCondition = () => {
    const cond: Condition = {
      id: uuidv4(),
      rule_id: draft.id,
      kind: "name",
      operator: "contains",
      value: "",
    };
    setDraft((d) => ({ ...d, conditions: [...d.conditions, cond] }));
  };

  const updateCondition = (index: number, patch: Partial<Condition>) => {
    setDraft((d) => {
      const conditions = d.conditions.map((c, i) =>
        i === index ? { ...c, ...patch } : c
      );
      return { ...d, conditions };
    });
  };

  const removeCondition = (index: number) => {
    setDraft((d) => ({
      ...d,
      conditions: d.conditions.filter((_, i) => i !== index),
    }));
  };

  const addAction = () => {
    const act: Action = {
      id: uuidv4(),
      rule_id: draft.id,
      kind: "move_to_folder",
      params: { destination: "" },
      position: draft.actions.length,
    };
    setDraft((d) => ({ ...d, actions: [...d.actions, act] }));
  };

  const updateAction = (index: number, patch: Partial<Action>) => {
    setDraft((d) => {
      const actions = d.actions.map((a, i) =>
        i === index ? { ...a, ...patch } : a
      );
      return { ...d, actions };
    });
  };

  const removeAction = (index: number) => {
    setDraft((d) => ({
      ...d,
      actions: d.actions.filter((_, i) => i !== index),
    }));
  };

  return (
    <div className="editor-overlay" onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="editor-panel">
        <div className="editor-header">
          <input
            ref={titleInputRef}
            className="editor-title-input"
            value={draft.name}
            onChange={(e) => setDraft((d) => ({ ...d, name: e.target.value }))}
          />
          <button className="editor-close" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        {/* Conditions */}
        <section className="editor-section">
          <div className="editor-section-header">
            <span>
              Files match when{" "}
              <select
                value={draft.condition_match}
                onChange={(e) =>
                  setDraft((d) => ({
                    ...d,
                    condition_match: e.target.value as ConditionMatch,
                  }))
                }
              >
                <option value="all">all conditions are true</option>
                <option value="any">at least one condition is true</option>
              </select>{" "}
              :
            </span>
            <button className="section-add-btn" onClick={addCondition}>
              <Plus size={12} />
            </button>
          </div>

          {draft.conditions.map((cond, i) => (
            <ConditionRow
              key={cond.id}
              condition={cond}
              onChange={(patch) => updateCondition(i, patch)}
              onRemove={() => removeCondition(i)}
            />
          ))}

          {draft.conditions.length === 0 && (
            <p className="editor-empty">No conditions — rule matches every file in the folder.</p>
          )}
        </section>

        {/* Scope */}
        <section className="editor-section">
          <div className="editor-section-header">
            <span>Scope</span>
          </div>

          <div className="scope-row">
            <div className="segmented scope-segmented">
              <button
                type="button"
                className={`segmented-option${isCurrentFolder ? " active" : ""}`}
                onClick={() => setDraft((d) => ({ ...d, recursion_depth: 0 }))}
              >
                Current folder
              </button>
              <button
                type="button"
                className={`segmented-option${isCurrentFolder ? "" : " active"}`}
                onClick={() =>
                  setDraft((d) => ({
                    ...d,
                    recursion_depth: d.recursion_depth === 0 ? 1 : d.recursion_depth ?? 1,
                  }))
                }
              >
                Subfolders
              </button>
            </div>

            {!isCurrentFolder && (
              <div className="scope-controls">
                <label className="scope-depth">
                  <span className="scope-label">Depth</span>
                  <input
                    className="scope-depth-input"
                    type="number"
                    min={1}
                    value={isInfinite ? "" : draft.recursion_depth ?? 1}
                    onChange={(e) => {
                      const next = Number(e.target.value);
                      setDraft((d) => ({
                        ...d,
                        recursion_depth: Number.isFinite(next) && next >= 1 ? Math.floor(next) : 1,
                      }));
                    }}
                    disabled={isInfinite}
                  />
                </label>

                <label className="scope-infinite">
                  <input
                    type="checkbox"
                    checked={isInfinite}
                    onChange={(e) =>
                      setDraft((d) => ({
                        ...d,
                        recursion_depth: e.target.checked ? null : d.recursion_depth ?? 1,
                      }))
                    }
                  />
                  <span>All levels</span>
                </label>
              </div>
            )}
          </div>
          <p className="scope-help">{scopeLabel(draft.recursion_depth)}</p>
        </section>

        {/* Actions */}
        <section className="editor-section">
          <div className="editor-section-header">
            <span>Do the following:</span>
            <button className="section-add-btn" onClick={addAction}>
              <Plus size={12} />
            </button>
          </div>

          {draft.actions.map((act, i) => (
            <ActionRow
              key={act.id}
              action={act}
              onChange={(patch) => updateAction(i, patch)}
              onRemove={() => removeAction(i)}
            />
          ))}

          {draft.actions.length === 0 && (
            <p className="editor-empty">No actions defined.</p>
          )}
        </section>

        <div className="editor-footer">
          {error ? (
            <p className="editor-error">{error}</p>
          ) : (
            <p className="editor-warning">
              {draft.enabled
                ? `This rule is active. Saving runs it now on every matching file in the configured scope.`
                : "This rule is inactive. Enable it in the list to apply it to the folder."}
            </p>
          )}
          <div className="editor-footer-actions">
            <button className="btn btn-secondary" onClick={onClose} disabled={saving}>
              Cancel
            </button>
            <button className="btn btn-primary" onClick={save} disabled={saving}>
              {saving ? "Saving..." : "Save"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

// ---------- Condition row ----------

function ConditionRow({
  condition,
  onChange,
  onRemove,
}: {
  condition: Condition;
  onChange: (p: Partial<Condition>) => void;
  onRemove: () => void;
}) {
  const ops = operatorsFor(condition.kind);
  const currentOp = ops.includes(condition.operator) ? condition.operator : ops[0];

  return (
    <div className="condition-row">
      <select
        value={condition.kind}
        onChange={(e) => {
          const kind = e.target.value as ConditionKind;
          let defaultValue = "";
          let defaultOp = operatorsFor(kind)[0];
          if (kind === "kind") defaultValue = KIND_OPTIONS[0].value;
          else if (kind === "color_label") defaultValue = COLOR_LABELS[0];
          else if (DATE_CONDITION_KINDS.includes(kind)) {
            defaultOp = "within_last";
            defaultValue = "7 days";
          }
          onChange({ kind, operator: defaultOp, value: defaultValue });
        }}
      >
        {(Object.keys(CONDITION_KIND_LABELS) as ConditionKind[]).map((k) => (
          <option key={k} value={k}>
            {CONDITION_KIND_LABELS[k]}
          </option>
        ))}
      </select>

      <select
        value={currentOp}
        onChange={(e) => onChange({ operator: e.target.value as Operator })}
      >
        {ops.map((op) => (
          <option key={op} value={op}>
            {OPERATOR_LABELS[op]}
          </option>
        ))}
      </select>

      {condition.kind === "kind" ? (
        <select
          className="condition-value"
          value={condition.value || KIND_OPTIONS[0].value}
          onChange={(e) => onChange({ value: e.target.value })}
        >
          {KIND_OPTIONS.map((opt) => (
            <option key={opt.value} value={opt.value}>
              {opt.label}
            </option>
          ))}
        </select>
      ) : condition.kind === "color_label" ? (
        <ColorDotPicker
          value={condition.value}
          onChange={(v) => onChange({ value: v })}
        />
      ) : condition.kind === "tags" ? (
        <TagPicker value={condition.value} onChange={(v) => onChange({ value: v })} />
      ) : condition.kind === "size_bytes" ? (
        <SizeValue value={condition.value} onChange={(v) => onChange({ value: v })} />
      ) : DATE_CONDITION_KINDS.includes(condition.kind) ? (
        <DateValue
          operator={currentOp}
          value={condition.value}
          onChange={(v) => onChange({ value: v })}
        />
      ) : (
        <input
          className="condition-value"
          value={condition.value}
          placeholder="value"
          onChange={(e) => onChange({ value: e.target.value })}
        />
      )}

      <button className="row-remove" onClick={onRemove}>
        <Minus size={12} />
      </button>
    </div>
  );
}

// ---------- Size value (number + unit) ----------

function SizeValue({
  value,
  onChange,
}: {
  value: string;
  onChange: (v: string) => void;
}) {
  // Stored as "<number> <unit>" (e.g. "5 MB"); plain numbers are treated as bytes.
  const match = value.trim().match(/^([\d.]*)\s*(bytes|kb|mb|gb)?$/i);
  const num = match?.[1] ?? "";
  const rawUnit = match?.[2]?.toLowerCase();
  const unit = SIZE_UNITS.find((u) => u.toLowerCase() === rawUnit) ?? "bytes";

  const emit = (n: string, u: string) => onChange(n ? `${n} ${u}` : "");

  return (
    <div className="size-value">
      <input
        className="condition-value"
        type="number"
        min={0}
        value={num}
        placeholder="0"
        onChange={(e) => emit(e.target.value, unit)}
      />
      <select value={unit} onChange={(e) => emit(num, e.target.value)}>
        {SIZE_UNITS.map((u) => (
          <option key={u} value={u}>
            {u}
          </option>
        ))}
      </select>
    </div>
  );
}

// ---------- Date value (absolute date or relative duration) ----------
//
// Keyed on the operator, not the condition kind, so it is reused by every date
// condition: before/after take a calendar date, older_than/within_last a duration.

function DateValue({
  operator,
  value,
  onChange,
}: {
  operator: Operator;
  value: string;
  onChange: (v: string) => void;
}) {
  if (operator === "before" || operator === "after") {
    return (
      <input
        className="condition-value"
        type="date"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    );
  }

  // Relative duration, stored as "<number> <unit>" (e.g. "30 days").
  const match = value.trim().match(/^(\d*)\s*(days|weeks|months|years)?$/i);
  const num = match?.[1] ?? "";
  const rawUnit = match?.[2]?.toLowerCase();
  const unit = DURATION_UNITS.find((u) => u === rawUnit) ?? "days";

  const emit = (n: string, u: string) => onChange(n ? `${n} ${u}` : "");

  return (
    <div className="size-value">
      <input
        className="condition-value"
        type="number"
        min={1}
        value={num}
        placeholder="0"
        onChange={(e) => emit(e.target.value, unit)}
      />
      <select value={unit} onChange={(e) => emit(num, e.target.value)}>
        {DURATION_UNITS.map((u) => (
          <option key={u} value={u}>
            {u}
          </option>
        ))}
      </select>
    </div>
  );
}

// ---------- Action row ----------

function ActionRow({
  action,
  onChange,
  onRemove,
}: {
  action: Action;
  onChange: (p: Partial<Action>) => void;
  onRemove: () => void;
}) {
  const needsFolder =
    action.kind === "move_to_folder" || action.kind === "copy_to_folder";
  const needsPattern = action.kind === "rename";
  const needsTag = action.kind === "add_tag" || action.kind === "remove_tag";
  const needsColorLabel = action.kind === "set_color_label";
  const needsScript = action.kind === "run_script";

  const pickFolder = async () => {
    const selected = await open({ directory: true, multiple: false });
    if (typeof selected === "string") {
      onChange({ params: { ...action.params, destination: selected } });
    }
  };

  return (
    <div className="action-row">
      <select
        value={action.kind}
        onChange={(e) => onChange({ kind: e.target.value as ActionKind, params: {} })}
      >
        {(Object.keys(ACTION_KIND_LABELS) as ActionKind[]).map((k) => (
          <option key={k} value={k}>
            {ACTION_KIND_LABELS[k]}
          </option>
        ))}
      </select>

      {needsFolder && (
        <div className="action-folder-picker">
          <input
            className="action-value"
            value={(action.params.destination as string | undefined) ?? ""}
            placeholder="Destination folder"
            readOnly
          />
          <button className="btn btn-secondary btn-sm" onClick={pickFolder}>
            Choose…
          </button>
        </div>
      )}

      {needsPattern && (
        <RenamePatternEditor
          value={(action.params.pattern as string | undefined) ?? ""}
          onChange={(pattern) =>
            onChange({ params: { ...action.params, pattern } })
          }
        />
      )}

      {needsTag && (
        <TagsInput
          tags={Array.isArray(action.params.tags) ? (action.params.tags as string[]) : []}
          onChange={(tags) => onChange({ params: { ...action.params, tags } })}
        />
      )}

      {needsColorLabel && (
        <ColorDotPicker
          value={(action.params.color as string | undefined) ?? ""}
          onChange={(color) => onChange({ params: { ...action.params, color } })}
          allowDeselect
        />
      )}

      {needsScript && (
        <textarea
          className="action-script"
          value={(action.params.script as string | undefined) ?? ""}
          placeholder="#!/bin/bash&#10;echo $FOREL_FILE"
          onChange={(e) =>
            onChange({ params: { ...action.params, script: e.target.value } })
          }
        />
      )}

      <button className="row-remove" onClick={onRemove}>
        <Minus size={12} />
      </button>
    </div>
  );
}

// ---------- Rename pattern editor ----------
//
// Uses a contenteditable div. Tokens are rendered as <span contenteditable="false">
// so the browser treats each one as a single atomic character — a single
// Backspace or Delete removes the whole token. Free text between tokens is
// editable normally. The DOM is the source of truth while editing; the pattern
// string is reconstructed by walking child nodes on every input event.

// Builds a human-readable preview using example values for each token.
function previewPattern(pattern: string): string {
  if (!pattern.trim()) return "";
  let result = pattern;
  for (const t of RENAME_TOKENS) {
    result = result.replace(new RegExp(`\\{${t.key}\\}`, "g"), t.example);
  }
  if (!pattern.includes("{extension}")) result = `${result}.pdf`;
  return result;
}

// Token key embedded as a data attribute in the DOM.
const TOKEN_ATTR = "data-token";

// Build the initial DOM HTML from a pattern string.
function patternToHtml(pattern: string): string {
  const re = /\{([^}]+)\}/g;
  let html = "";
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(pattern)) !== null) {
    if (m.index > last) html += escapeHtml(pattern.slice(last, m.index));
    const key = m[1];
    const token = RENAME_TOKENS.find((t) => t.key === key);
    if (token) {
      html += tokenChipHtml(key, token.label);
    } else {
      html += escapeHtml(m[0]);
    }
    last = m.index + m[0].length;
  }
  if (last < pattern.length) html += escapeHtml(pattern.slice(last));
  return html;
}

function tokenChipHtml(key: string, label: string): string {
  return `<span contenteditable="false" ${TOKEN_ATTR}="${key}" class="rename-token-chip">${escapeHtml(label)}</span>`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Walk the contenteditable DOM and reconstruct the pattern string.
function domToPattern(el: HTMLElement): string {
  let result = "";
  el.childNodes.forEach((node) => {
    if (node.nodeType === Node.TEXT_NODE) {
      result += node.textContent ?? "";
    } else if (node.nodeType === Node.ELEMENT_NODE) {
      const span = node as HTMLElement;
      const key = span.getAttribute(TOKEN_ATTR);
      if (key) {
        result += `{${key}}`;
      } else {
        // Nested element without token attr (e.g. a <br> inserted by the browser)
        result += span.textContent ?? "";
      }
    }
  });
  return result;
}

function RenamePatternEditor({
  value,
  onChange,
}: {
  value: string;
  onChange: (pattern: string) => void;
}) {
  const editorRef = useRef<HTMLDivElement>(null);
  const [focused, setFocused] = useState(false);
  // Track the last pattern we wrote into the DOM so we don't clobber the DOM
  // on re-renders triggered by our own onChange calls.
  const lastWritten = useRef<string | null>(null);

  // Initialise or sync the DOM when value changes from outside.
  useEffect(() => {
    const el = editorRef.current;
    if (!el) return;
    if (lastWritten.current === value) return; // our own change, skip
    lastWritten.current = value;
    el.innerHTML = patternToHtml(value);
  }, [value]);

  const handleInput = () => {
    const el = editorRef.current;
    if (!el) return;
    const pattern = domToPattern(el);
    lastWritten.current = pattern;
    onChange(pattern);
  };

  const insertToken = (key: string) => {
    const el = editorRef.current;
    if (!el) return;
    el.focus();

    const token = RENAME_TOKENS.find((t) => t.key === key);
    if (!token) return;

    // Insert the chip at the current selection position.
    const sel = window.getSelection();
    if (sel && sel.rangeCount > 0) {
      const range = sel.getRangeAt(0);
      range.deleteContents();

      const chip = document.createElement("span");
      chip.setAttribute("contenteditable", "false");
      chip.setAttribute(TOKEN_ATTR, key);
      chip.className = "rename-token-chip";
      chip.textContent = token.label;
      range.insertNode(chip);

      // Place cursor after the inserted chip.
      range.setStartAfter(chip);
      range.collapse(true);
      sel.removeAllRanges();
      sel.addRange(range);
    } else {
      // No selection — append at end.
      const chip = document.createElement("span");
      chip.setAttribute("contenteditable", "false");
      chip.setAttribute(TOKEN_ATTR, key);
      chip.className = "rename-token-chip";
      chip.textContent = token.label;
      el.appendChild(chip);
    }

    handleInput();
  };

  // Arrow keys: skip over token chips atomically so the cursor never lands inside one.
  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") { e.preventDefault(); return; }

    const isLeft  = e.key === "ArrowLeft";
    const isRight = e.key === "ArrowRight";
    if (!isLeft && !isRight) return;

    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return;
    const range = sel.getRangeAt(0);

    // Only act when the cursor is collapsed (no selection) or shift-selecting.
    // For shift+arrow we still want to skip the whole token.
    const node = isRight ? range.endContainer : range.startContainer;
    const offset = isRight ? range.endOffset : range.startOffset;

    if (isRight) {
      // Check what's immediately to the right of the cursor.
      let sibling: ChildNode | null = null;
      if (node.nodeType === Node.TEXT_NODE) {
        // Are we at the end of this text node?
        if (offset === node.textContent!.length) {
          sibling = node.nextSibling;
        }
      } else if (node.nodeType === Node.ELEMENT_NODE) {
        sibling = (node as Element).childNodes[offset] ?? null;
      }

      if (sibling && (sibling as HTMLElement).getAttribute?.(TOKEN_ATTR)) {
        e.preventDefault();
        const newRange = document.createRange();
        newRange.setStartAfter(sibling);
        newRange.collapse(true);
        if (!e.shiftKey) {
          sel.removeAllRanges();
          sel.addRange(newRange);
        } else {
          sel.extend(newRange.startContainer, newRange.startOffset);
        }
      }
    } else {
      // ArrowLeft — check what's immediately to the left.
      let sibling: ChildNode | null = null;
      if (node.nodeType === Node.TEXT_NODE) {
        if (offset === 0) {
          sibling = node.previousSibling;
        }
      } else if (node.nodeType === Node.ELEMENT_NODE) {
        sibling = (node as Element).childNodes[offset - 1] ?? null;
      }

      if (sibling && (sibling as HTMLElement).getAttribute?.(TOKEN_ATTR)) {
        e.preventDefault();
        const newRange = document.createRange();
        newRange.setStartBefore(sibling);
        newRange.collapse(true);
        if (!e.shiftKey) {
          sel.removeAllRanges();
          sel.addRange(newRange);
        } else {
          sel.extend(newRange.startContainer, newRange.startOffset);
        }
      }
    }
  };

  const activeTokens = new Set(
    [...value.matchAll(/\{([^}]+)\}/g)]
      .map((m) => m[1])
      .filter((k) => RENAME_TOKENS.some((t) => t.key === k))
  );

  return (
    <div className="rename-pattern-editor">
      <div
        ref={editorRef}
        className={`rename-ce${focused ? " rename-ce--focused" : ""}`}
        contentEditable
        suppressContentEditableWarning
        onInput={handleInput}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        onKeyDown={handleKeyDown}
        spellCheck={false}
        data-placeholder="click tokens below to build a pattern"
      />
      {/* Token palette */}
      <div className="rename-token-palette">
        {RENAME_TOKENS.map((t) => (
          <button
            key={t.key}
            type="button"
            className={`rename-palette-btn${activeTokens.has(t.key) ? " rename-palette-btn--used" : ""}`}
            onMouseDown={(e) => {
              e.preventDefault(); // keep focus in editor
              insertToken(t.key);
            }}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Live preview */}
      {value.trim() && (
        <div className="rename-preview">
          <span className="rename-preview-label">Preview: </span>
          <span className="rename-preview-value">{previewPattern(value)}</span>
        </div>
      )}
    </div>
  );
}

// ---------- Text tag picker ----------
//
// Tags are free-form text labels, distinct from the colored Finder labels
// (handled separately by the color-label picker). The 7 system color names
// are filtered out here so they only appear as color labels, not as tags.

function TagPicker({
  value,
  onChange,
}: {
  value: string;
  onChange: (tag: string) => void;
}) {
  const [tags, setTags] = useState<string[]>([]);
  const [customInput, setCustomInput] = useState("");

  const loadTags = () => {
    invoke<string[]>("get_macos_tags")
      .then(setTags)
      .catch(() => {});
  };

  useEffect(loadTags, []);

  const applyCustom = async () => {
    const tag = customInput.trim();
    if (!tag) return;
    await invoke("add_custom_tag", { name: tag }).catch(() => {});
    onChange(tag);
    setCustomInput("");
    loadTags();
  };

  return (
    <div className="tag-picker-wrap">
      {tags.length > 0 && (
        <div className="tag-user-list">
          {tags.map((tag) => (
            <button
              key={tag}
              type="button"
              className={`tag-user-pill${value === tag ? " tag-user-pill--active" : ""}`}
              onClick={() => onChange(value === tag ? "" : tag)}
            >
              {tag}
            </button>
          ))}
        </div>
      )}

      <div className="tag-custom-input-row">
        <input
          className="tag-custom-input"
          value={customInput}
          placeholder="Add a tag…"
          onChange={(e) => setCustomInput(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && applyCustom()}
        />
        <button
          className="btn btn-secondary btn-sm"
          type="button"
          onClick={applyCustom}
          disabled={!customInput.trim()}
        >
          <Plus size={11} />
        </button>
      </div>

      {value && !tags.includes(value) && (
        <div className="tag-custom-selected">
          <span className="tag-custom-label">{value}</span>
          <button type="button" className="tag-custom-clear" onClick={() => onChange("")}>
            <X size={10} />
          </button>
        </div>
      )}
    </div>
  );
}
