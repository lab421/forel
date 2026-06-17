import { ChevronDown, Eye, GripVertical, Play, Plus, Trash2, X } from "lucide-react";
import { type DragEvent, useRef, useState } from "react";
import { useForelStore } from "../store";
import { PreviewResult, Rule } from "../types";
import RuleEditor from "./RuleEditor";

export default function RuleList() {
  const {
    selectedFolderId,
    folders,
    rules,
    loading,
    createRule,
    deleteRule,
    fetchRules,
    reorderRules,
    toggleRule,
    runRulesNow,
    previewRules,
  } = useForelStore();

  const [editingRule, setEditingRule] = useState<Rule | null>(null);
  const [autoFocusEditorTitle, setAutoFocusEditorTitle] = useState(false);
  const [runResult, setRunResult] = useState<number | null>(null);
  const [previewResult, setPreviewResult] = useState<PreviewResult | null>(null);
  const [previewFolderId, setPreviewFolderId] = useState<string | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [draggedRuleId, setDraggedRuleId] = useState<string | null>(null);
  const [dragOverRuleId, setDragOverRuleId] = useState<string | null>(null);
  const [dragRuleIds, setDragRuleIds] = useState<string[] | null>(null);
  const draggedRuleIdRef = useRef<string | null>(null);

  const selectedFolder = folders.find((f) => f.id === selectedFolderId);
  const visibleRules = dragRuleIds
    ? dragRuleIds
        .map((id) => rules.find((rule) => rule.id === id))
        .filter((rule): rule is Rule => Boolean(rule))
    : rules;
  const visiblePreview =
    previewFolderId === selectedFolderId ? previewResult : null;

  const clearPreview = () => {
    setPreviewResult(null);
    setPreviewFolderId(null);
  };

  const handleAdd = async () => {
    if (!selectedFolderId) return;
    clearPreview();
    const rule = await createRule(selectedFolderId, "New Rule");
    setAutoFocusEditorTitle(true);
    setEditingRule(rule);
  };

  const handleEdit = (rule: Rule) => {
    clearPreview();
    setAutoFocusEditorTitle(false);
    setEditingRule(rule);
  };

  const handleCloseEditor = () => {
    setEditingRule(null);
    setAutoFocusEditorTitle(false);
  };

  const handleRunNow = async () => {
    if (!selectedFolderId) return;
    clearPreview();
    const modifiedCount = await runRulesNow(selectedFolderId);
    setRunResult(modifiedCount);
    setTimeout(() => setRunResult(null), 4000);
  };

  const handlePreview = async () => {
    if (!selectedFolderId) return;
    setPreviewing(true);
    try {
      const result = await previewRules(selectedFolderId);
      setPreviewResult(result);
      setPreviewFolderId(selectedFolderId);
    } finally {
      setPreviewing(false);
    }
  };

  const handleToggle = async (ruleId: string, enabled: boolean) => {
    clearPreview();
    await toggleRule(ruleId, enabled);
  };

  const handleDelete = async (ruleId: string) => {
    clearPreview();
    await deleteRule(ruleId);
  };

  const handleDragStart = (event: DragEvent, ruleId: string) => {
    const target = event.target instanceof HTMLElement ? event.target : null;
    if (target?.closest("button, input, label")) {
      event.preventDefault();
      return;
    }

    draggedRuleIdRef.current = ruleId;
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", ruleId);
    setDraggedRuleId(ruleId);
    setDragRuleIds(rules.map((rule) => rule.id));
  };

  const handleDragOver = (event: DragEvent, ruleId: string) => {
    const sourceRuleId = draggedRuleIdRef.current;
    if (!sourceRuleId || sourceRuleId === ruleId) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    setDragOverRuleId(ruleId);

    setDragRuleIds((current) => {
      const orderedIds = current ?? rules.map((rule) => rule.id);
      const fromIndex = orderedIds.indexOf(sourceRuleId);
      const toIndex = orderedIds.indexOf(ruleId);
      if (fromIndex === -1 || toIndex === -1 || fromIndex === toIndex) {
        return orderedIds;
      }

      const next = [...orderedIds];
      const [moved] = next.splice(fromIndex, 1);
      next.splice(toIndex, 0, moved);
      return next;
    });
  };

  const handleDrop = async (event: DragEvent) => {
    event.preventDefault();
    event.stopPropagation();
    const sourceRuleId =
      draggedRuleIdRef.current || event.dataTransfer.getData("text/plain");

    if (!selectedFolderId || !sourceRuleId) {
      draggedRuleIdRef.current = null;
      setDraggedRuleId(null);
      setDragOverRuleId(null);
      setDragRuleIds(null);
      return;
    }

    const orderedIds = dragRuleIds ?? rules.map((rule) => rule.id);
    if (!orderedIds.includes(sourceRuleId)) {
      draggedRuleIdRef.current = null;
      setDraggedRuleId(null);
      setDragOverRuleId(null);
      setDragRuleIds(null);
      return;
    }

    clearPreview();

    try {
      await reorderRules(selectedFolderId, orderedIds);
    } catch (error) {
      console.error("Failed to reorder rules", error);
      await fetchRules(selectedFolderId);
    } finally {
      draggedRuleIdRef.current = null;
      setDraggedRuleId(null);
      setDragOverRuleId(null);
      setDragRuleIds(null);
    }
  };

  const handleDragEnd = () => {
    draggedRuleIdRef.current = null;
    setDraggedRuleId(null);
    setDragOverRuleId(null);
    setDragRuleIds(null);
  };

  if (!selectedFolderId) {
    return (
      <main className="rule-list-empty">
        <p>Select a folder on the left to manage its rules.</p>
      </main>
    );
  }

  return (
    <main className="rule-list">
      <header className="rule-list-header">
        <div>
          <h2 className="rule-list-title">{selectedFolder?.path.split("/").pop()}</h2>
          <p className="rule-list-subtitle">{selectedFolder?.path}</p>
        </div>
        <div className="rule-list-actions">
          <button
            className="btn btn-secondary"
            onClick={handlePreview}
            disabled={previewing}
            title="Preview what rules would do"
          >
            <Eye size={13} /> {previewing ? "Previewing…" : "Preview"}
          </button>
          <button className="btn btn-secondary" onClick={handleRunNow} title="Run rules now">
            <Play size={13} /> Run now
          </button>
          <button className="btn btn-primary" onClick={handleAdd}>
            <Plus size={13} /> Add Rule
          </button>
        </div>
      </header>

      <div className="rule-order-hint">Rules run top to bottom. Higher rules execute first.</div>

      {runResult !== null && (
        <div className="run-result">
          {runResult === 0
            ? "Success: 0 files modified."
            : `Success: ${runResult} file${runResult !== 1 ? "s" : ""} modified.`}
        </div>
      )}

      {visiblePreview && (
        <section className="preview-panel">
          <div className="preview-header">
            <div>
              <h3 className="preview-title">Preview</h3>
              <p className="preview-summary">
                {visiblePreview.files_scanned} file
                {visiblePreview.files_scanned !== 1 ? "s" : ""} scanned,{" "}
                {visiblePreview.matches.length} file
                {visiblePreview.matches.length !== 1 ? "s" : ""} with matching rules.
              </p>
            </div>
            <button
              className="preview-close"
              type="button"
              onClick={clearPreview}
              title="Close preview"
            >
              <X size={13} />
            </button>
          </div>

          {visiblePreview.matches.length === 0 ? (
            <div className="preview-empty">No files would be changed.</div>
          ) : (
            <div className="preview-list">
              {visiblePreview.matches.map((file) => (
                <article className="preview-file" key={file.path}>
                  <div className="preview-file-name">{file.name || file.path}</div>
                  <div className="preview-file-path">{file.path}</div>
                  <div className="preview-rules">
                    {file.rules.map((rule) => (
                      <div className="preview-rule" key={rule.rule_id}>
                        <div className="preview-rule-name">{rule.rule_name}</div>
                        {rule.actions.length === 0 ? (
                          <div className="preview-action preview-action-empty">
                            No actions configured.
                          </div>
                        ) : (
                          <ul className="preview-actions">
                            {rule.actions.map((action, index) => (
                              <li className="preview-action" key={`${rule.rule_id}-${index}`}>
                                {action}
                              </li>
                            ))}
                          </ul>
                        )}
                      </div>
                    ))}
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      )}

      {loading ? (
        <div className="rule-loading">Loading…</div>
      ) : visibleRules.length === 0 ? (
        <div className="rule-empty">
          No rules yet — click <strong>Add Rule</strong> to create one.
        </div>
      ) : (
        <ul className="rules" onDragOver={(event) => event.preventDefault()} onDrop={handleDrop}>
          {visibleRules.map((rule, index) => (
            <RuleRow
              key={rule.id}
              rule={rule}
              index={index}
              onEdit={() => handleEdit(rule)}
              onToggle={(enabled) => handleToggle(rule.id, enabled)}
              onDelete={() => handleDelete(rule.id)}
              dragging={draggedRuleId === rule.id}
              dragOver={dragOverRuleId === rule.id}
              onDragStart={(event) => handleDragStart(event, rule.id)}
              onDragOver={(event) => handleDragOver(event, rule.id)}
              onDrop={handleDrop}
              onDragEnd={handleDragEnd}
            />
          ))}
        </ul>
      )}

      {editingRule && (
        <RuleEditor
          rule={editingRule}
          autoFocusTitle={autoFocusEditorTitle}
          onClose={handleCloseEditor}
          onSaved={clearPreview}
        />
      )}
    </main>
  );
}

function RuleRow({
  rule,
  index,
  onEdit,
  onToggle,
  onDelete,
  dragging,
  dragOver,
  onDragStart,
  onDragOver,
  onDrop,
  onDragEnd,
}: {
  rule: Rule;
  index: number;
  onEdit: () => void;
  onToggle: (v: boolean) => void;
  onDelete: () => void;
  dragging: boolean;
  dragOver: boolean;
  onDragStart: (event: DragEvent) => void;
  onDragOver: (event: DragEvent) => void;
  onDrop: (event: DragEvent) => void;
  onDragEnd: () => void;
}) {
  const conditionSummary =
    rule.conditions.length === 0
      ? "every file in the folder"
      : `${rule.conditions.length} condition${rule.conditions.length !== 1 ? "s" : ""}`;

  return (
    <li
      className={`rule-row ${rule.enabled ? "" : "rule-disabled"} ${dragging ? "rule-dragging" : ""} ${dragOver ? "rule-drag-over" : ""}`}
      draggable
      onDragStart={onDragStart}
      onDragOver={onDragOver}
      onDrop={onDrop}
      onDragEnd={onDragEnd}
    >
      <div
        className="rule-order"
        title="Drag to reorder"
      >
        <GripVertical className="rule-drag-handle" size={13} aria-hidden="true" />
        <span className="rule-order-badge">{index + 1}</span>
        <span className="rule-order-line" />
        <ChevronDown className="rule-order-arrow" size={10} />
      </div>
      <label className="switch" title={rule.enabled ? "Enabled" : "Disabled"}>
        <input
          type="checkbox"
          checked={rule.enabled}
          onChange={(e) => onToggle(e.target.checked)}
        />
        <span className="switch-slider" />
      </label>
      <div className="rule-info" onClick={onEdit}>
        <span className="rule-name">{rule.name}</span>
        <span className="rule-summary">
          {conditionSummary},{" "}
          {rule.actions.length} action{rule.actions.length !== 1 ? "s" : ""}
        </span>
        <span className="rule-scope">{scopeLabel(rule.recursion_depth)}</span>
      </div>
      <button className="rule-delete" onClick={onDelete} title="Delete rule">
        <Trash2 size={13} />
      </button>
    </li>
  );
}

function scopeLabel(depth: number | null) {
  if (depth === null) return "All subfolders";
  if (depth === 0) return "Current folder";
  if (depth === 1) return "1 subfolder level";
  return `${depth} subfolder levels`;
}
