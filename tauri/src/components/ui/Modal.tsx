import { X } from "lucide-react";
import type { ReactNode } from "react";

interface ModalProps {
  onClose: () => void;
  children: ReactNode;
}

/** Backdrop overlay — click outside closes. */
export function Modal({ onClose, children }: ModalProps) {
  return (
    <div
      className="editor-overlay"
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      {children}
    </div>
  );
}

interface ModalPanelProps {
  className?: string;
  children: ReactNode;
}

/** The white/dark card that floats on the overlay. */
export function ModalPanel({ className = "editor-panel", children }: ModalPanelProps) {
  return <div className={className}>{children}</div>;
}

interface ModalHeaderProps {
  title: ReactNode;
  onClose: () => void;
}

/** Header row with a title slot and a close button. */
export function ModalHeader({ title, onClose }: ModalHeaderProps) {
  return (
    <div className="editor-header">
      <div style={{ flex: 1 }}>{title}</div>
      <button className="editor-close" onClick={onClose} title="Close">
        <X size={16} />
      </button>
    </div>
  );
}

interface ModalFooterProps {
  onCancel: () => void;
  onConfirm: () => void;
  confirmLabel?: string;
  cancelLabel?: string;
}

/** Footer with cancel + confirm buttons. */
export function ModalFooter({
  onCancel,
  onConfirm,
  confirmLabel = "Save",
  cancelLabel = "Cancel",
}: ModalFooterProps) {
  return (
    <div className="editor-footer">
      <button className="btn btn-secondary" onClick={onCancel}>
        {cancelLabel}
      </button>
      <button className="btn btn-primary" onClick={onConfirm}>
        {confirmLabel}
      </button>
    </div>
  );
}
