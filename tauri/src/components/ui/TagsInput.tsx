import { X } from "lucide-react";
import { useRef, useState } from "react";

interface TagsInputProps {
  tags: string[];
  onChange: (tags: string[]) => void;
  placeholder?: string;
}

/**
 * Chip-based multi-value text input.
 * Enter or Tab commits a chip; Backspace on empty removes the last one.
 * Used by add_tag / remove_tag actions, and anywhere a list of strings is needed.
 */
export function TagsInput({ tags, onChange, placeholder = "Add tags…" }: TagsInputProps) {
  const [input, setInput] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  const commit = () => {
    const tag = input.trim();
    if (tag && !tags.includes(tag)) onChange([...tags, tag]);
    setInput("");
  };

  return (
    <div className="tags-list-input" onClick={() => inputRef.current?.focus()}>
      {tags.map((tag) => (
        <span key={tag} className="tags-list-chip">
          {tag}
          <button
            type="button"
            className="tags-list-chip-remove"
            onClick={(e) => {
              e.stopPropagation();
              onChange(tags.filter((t) => t !== tag));
            }}
          >
            <X size={9} />
          </button>
        </span>
      ))}
      <input
        ref={inputRef}
        className="tags-list-inline-input"
        value={input}
        placeholder={tags.length === 0 ? placeholder : ""}
        onChange={(e) => setInput(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === "Tab") {
            e.preventDefault();
            commit();
          } else if (e.key === "Backspace" && !input && tags.length > 0) {
            onChange(tags.slice(0, -1));
          }
        }}
        onBlur={commit}
      />
    </div>
  );
}
