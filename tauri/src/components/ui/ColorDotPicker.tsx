import { Check } from "lucide-react";
import { COLOR_LABELS, MACOS_TAG_COLORS } from "./colors";

export type { ColorLabel } from "./colors";
export { COLOR_LABELS, MACOS_TAG_COLORS } from "./colors";

interface ColorDotPickerProps {
  /** Currently selected color label, or empty string for none. */
  value: string;
  onChange: (color: string) => void;
  /** If true, clicking the active dot deselects it (useful for actions). */
  allowDeselect?: boolean;
}

/**
 * Row of 7 macOS Finder color dots.
 * Used in both ConditionRow (single-select) and ActionRow (with deselect).
 */
export function ColorDotPicker({ value, onChange, allowDeselect = false }: ColorDotPickerProps) {
  return (
    <div className="tag-picker">
      {COLOR_LABELS.map((label) => {
        const selected = value === label;
        return (
          <button
            key={label}
            type="button"
            className={`tag-dot${selected ? " tag-dot--active" : ""}`}
            style={{ backgroundColor: MACOS_TAG_COLORS[label] }}
            title={label}
            onClick={() => onChange(allowDeselect && selected ? "" : label)}
          >
            {selected && <Check size={9} color="#fff" strokeWidth={3} />}
          </button>
        );
      })}
    </div>
  );
}
