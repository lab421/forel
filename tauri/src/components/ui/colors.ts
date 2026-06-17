// macOS Finder color labels — used by ColorDotPicker and condition/action logic.
export const COLOR_LABELS = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"] as const;
export type ColorLabel = (typeof COLOR_LABELS)[number];

export const MACOS_TAG_COLORS: Record<ColorLabel, string> = {
  Red:    "#FF3B30",
  Orange: "#FF9500",
  Yellow: "#FFCC00",
  Green:  "#34C759",
  Blue:   "#007AFF",
  Purple: "#AF52DE",
  Gray:   "#8E8E93",
};
