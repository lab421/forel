interface SwitchProps {
  checked: boolean;
  onChange: (checked: boolean) => void;
  title?: string;
}

/** macOS-style toggle switch. */
export function Switch({ checked, onChange, title }: SwitchProps) {
  return (
    <label className="switch" title={title}>
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span className="switch-slider" />
    </label>
  );
}
