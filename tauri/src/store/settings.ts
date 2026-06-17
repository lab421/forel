import { create } from "zustand";

export type Theme = "system" | "light" | "dark";

const STORAGE_KEY = "forel.theme";

/** Applies the theme to the document root. "system" follows the OS setting. */
function applyTheme(theme: Theme) {
  const root = document.documentElement;
  if (theme === "system") {
    root.removeAttribute("data-theme");
  } else {
    root.setAttribute("data-theme", theme);
  }
}

const initialTheme = (localStorage.getItem(STORAGE_KEY) as Theme) || "system";
applyTheme(initialTheme);

interface SettingsState {
  theme: Theme;
  setTheme: (theme: Theme) => void;
}

export const useSettings = create<SettingsState>((set) => ({
  theme: initialTheme,
  setTheme: (theme) => {
    localStorage.setItem(STORAGE_KEY, theme);
    applyTheme(theme);
    set({ theme });
  },
}));
