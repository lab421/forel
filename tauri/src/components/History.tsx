import { ArrowRight, Folder, RotateCcw, Trash2, Undo2, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { useForelStore } from "../store";
import { ACTION_KIND_LABELS, HistoryEntry } from "../types";

interface Props {
  onClose: () => void;
}

interface Batch {
  id: string;
  at: string;
  entries: HistoryEntry[];
}

function basename(path: string): string {
  const parts = path.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? path;
}

// Directory shared by all the files a batch acted on (their common parent).
function commonDir(entries: HistoryEntry[]): string {
  const dirs = entries.map((e) => e.original_path.split("/").slice(0, -1));
  if (dirs.length === 0) return "";
  let prefix = dirs[0];
  for (const dir of dirs.slice(1)) {
    let i = 0;
    while (i < prefix.length && i < dir.length && prefix[i] === dir[i]) i++;
    prefix = prefix.slice(0, i);
  }
  return prefix.join("/") || "/";
}

function formatTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString();
}

// History comes newest-first; preserve that order while grouping by batch.
function groupByBatch(history: HistoryEntry[]): Batch[] {
  const batches: Batch[] = [];
  const index = new Map<string, Batch>();
  for (const entry of history) {
    let batch = index.get(entry.batch_id);
    if (!batch) {
      batch = { id: entry.batch_id, at: entry.created_at, entries: [] };
      index.set(entry.batch_id, batch);
      batches.push(batch);
    }
    batch.entries.push(entry);
  }
  return batches;
}

function hasAppliedEntries(batch: Batch): boolean {
  return batch.entries.some((e) => e.status === "applied");
}

function newestAppliedBatchByDir(batches: Batch[]): Map<string, string> {
  const newest = new Map<string, string>();
  for (const batch of batches) {
    const dir = commonDir(batch.entries);
    if (hasAppliedEntries(batch) && !newest.has(dir)) {
      newest.set(dir, batch.id);
    }
  }
  return newest;
}

export default function History({ onClose }: Props) {
  const { history, historyLoading, fetchHistory, undoEntry, undoBatch, clearHistory } =
    useForelStore();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void fetchHistory();
  }, [fetchHistory]);

  const batches = useMemo(() => groupByBatch(history), [history]);
  const newestAppliedByDir = useMemo(() => newestAppliedBatchByDir(batches), [batches]);

  const run = async (fn: () => Promise<unknown>) => {
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const handleUndoBatch = (batchId: string) =>
    run(async () => {
      const summary = await undoBatch(batchId);
      if (summary.failed.length > 0) {
        setError(
          `${summary.undone} undone, ${summary.failed.length} failed: ${summary.failed.join("; ")}`,
        );
      }
    });

  return (
    <div className="editor-overlay" onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="history-panel">
        <header className="history-header">
          <h2 className="history-title">Activity</h2>
          <div className="history-header-actions">
            <button
              className="btn btn-secondary btn-sm"
              onClick={() => run(clearHistory)}
              disabled={history.length === 0}
              title="Delete the history (does not touch files)"
            >
              <Trash2 size={13} /> Clear
            </button>
            <button className="editor-close" onClick={onClose} title="Close">
              <X size={16} />
            </button>
          </div>
        </header>

        {error && <p className="history-error">{error}</p>}

        {historyLoading ? (
          <div className="history-empty">Loading…</div>
        ) : batches.length === 0 ? (
          <div className="history-empty">No actions have run yet.</div>
        ) : (
          <div className="history-list">
            {batches.map((batch) => {
              const batchDir = commonDir(batch.entries);
              const canUndoBatch = batch.entries.some(
                (e) => e.reversible && e.status === "applied",
              );
              const isNewestAppliedBatch = newestAppliedByDir.get(batchDir) === batch.id;
              const undoDisabled = !canUndoBatch || !isNewestAppliedBatch;
              const undoTitle = !canUndoBatch
                ? "No reversible applied actions in this run"
                : !isNewestAppliedBatch
                  ? "Undo newer activity in this folder first"
                  : "Undo every reversible action in this run";
              return (
                <section className="history-batch" key={batch.id}>
                  <div className="history-batch-header">
                    <div className="history-batch-info">
                      <span
                        className="history-batch-dir"
                        title={batchDir}
                      >
                        <Folder size={12} className="history-batch-dir-icon" />
                        {batchDir}
                      </span>
                      <span className="history-batch-meta">
                        {formatTime(batch.at)} · {batch.entries.length} action
                        {batch.entries.length !== 1 ? "s" : ""}
                      </span>
                    </div>
                    <button
                      className="btn btn-secondary btn-sm"
                      onClick={() => handleUndoBatch(batch.id)}
                      disabled={undoDisabled}
                      title={undoTitle}
                    >
                      <Undo2 size={13} /> Undo batch
                    </button>
                  </div>

                  <ul className="history-entries">
                    {batch.entries.map((entry) => (
                      <li className="history-entry" key={entry.id}>
                        <div className="history-entry-main">
                          <span className="history-entry-action">
                            {ACTION_KIND_LABELS[entry.action_kind]}
                          </span>
                          <span className="history-entry-rule">{entry.rule_name}</span>
                        </div>
                        <div className="history-entry-paths">
                          <span title={entry.original_path}>{basename(entry.original_path)}</span>
                          {entry.result_path !== entry.original_path && (
                            <>
                              <ArrowRight size={11} className="history-arrow" />
                              <span title={entry.result_path}>{basename(entry.result_path)}</span>
                            </>
                          )}
                        </div>
                        <div className="history-entry-side">
                          {entry.status === "undone" ? (
                            <span className="history-badge history-badge-undone">Undone</span>
                          ) : entry.reversible ? (
                            <button
                              className="history-undo-btn"
                              onClick={() => run(() => undoEntry(entry.id))}
                              title="Undo this action"
                            >
                              <RotateCcw size={13} />
                            </button>
                          ) : (
                            <span className="history-badge">Not undoable</span>
                          )}
                        </div>
                      </li>
                    ))}
                  </ul>
                </section>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
