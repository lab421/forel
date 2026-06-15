import { invoke } from "@tauri-apps/api/core";
import { getVersion } from "@tauri-apps/api/app";
import { relaunch } from "@tauri-apps/plugin-process";
import { check, type Update } from "@tauri-apps/plugin-updater";
import { create } from "zustand";
import {
  PreviewResult,
  Rule,
  UpdateInfo,
  UpdateStatus,
  WatchedFolder,
} from "../types";

const releaseUrl = (version: string) =>
  `https://github.com/lguichard/forel/releases/tag/${
    version.startsWith("v") ? version : `v${version}`
  }`;

interface ForelState {
  folders: WatchedFolder[];
  selectedFolderId: string | null;
  rules: Rule[];
  loading: boolean;
  updateStatus: UpdateStatus;
  updateInfo: UpdateInfo | null;
  pendingUpdate: Update | null;

  // Folder actions
  fetchFolders: () => Promise<void>;
  addFolder: (path: string) => Promise<void>;
  removeFolder: (id: string) => Promise<void>;
  toggleFolder: (id: string, enabled: boolean) => Promise<void>;
  selectFolder: (id: string | null) => void;

  // Rule actions
  fetchRules: (folderId: string) => Promise<void>;
  createRule: (folderId: string, name: string) => Promise<Rule>;
  updateRule: (rule: Rule) => Promise<void>;
  deleteRule: (ruleId: string) => Promise<void>;
  toggleRule: (ruleId: string, enabled: boolean) => Promise<void>;
  runRule: (ruleId: string) => Promise<string[]>;
  runRulesNow: (folderId: string) => Promise<string[]>;
  previewRules: (folderId: string) => Promise<PreviewResult>;

  // Update actions
  checkForUpdates: () => Promise<void>;
  installUpdate: () => Promise<void>;
}

export const useForelStore = create<ForelState>((set, get) => ({
  folders: [],
  selectedFolderId: null,
  rules: [],
  loading: false,
  updateStatus: "idle",
  updateInfo: null,
  pendingUpdate: null,

  fetchFolders: async () => {
    const folders = await invoke<WatchedFolder[]>("get_watched_folders");
    set({ folders });
  },

  addFolder: async (path) => {
    const folder = await invoke<WatchedFolder>("add_watched_folder", { path });
    set((s) => ({ folders: [...s.folders, folder] }));
  },

  removeFolder: async (id) => {
    await invoke("remove_watched_folder", { id });
    set((s) => ({
      folders: s.folders.filter((f) => f.id !== id),
      selectedFolderId: s.selectedFolderId === id ? null : s.selectedFolderId,
      rules: s.selectedFolderId === id ? [] : s.rules,
    }));
  },

  toggleFolder: async (id, enabled) => {
    await invoke("toggle_watched_folder", { id, enabled });
    set((s) => ({
      folders: s.folders.map((f) => (f.id === id ? { ...f, enabled } : f)),
    }));
  },

  selectFolder: (id) => {
    set({ selectedFolderId: id, rules: [] });
    if (id) void get().fetchRules(id);
  },

  fetchRules: async (folderId) => {
    set({ loading: true });
    try {
      const rules = await invoke<Rule[]>("get_rules", { folderId });
      set({ rules });
    } finally {
      set({ loading: false });
    }
  },

  createRule: async (folderId, name) => {
    const rule = await invoke<Rule>("create_rule", { folderId, name });
    set((s) => ({ rules: [...s.rules, rule] }));
    return rule;
  },

  updateRule: async (rule) => {
    await invoke("update_rule", { rule });
    set((s) => ({
      rules: s.rules.map((r) => (r.id === rule.id ? rule : r)),
    }));
  },

  deleteRule: async (ruleId) => {
    await invoke("delete_rule", { ruleId });
    set((s) => ({ rules: s.rules.filter((r) => r.id !== ruleId) }));
  },

  toggleRule: async (ruleId, enabled) => {
    await invoke("toggle_rule", { ruleId, enabled });
    set((s) => ({
      rules: s.rules.map((r) => (r.id === ruleId ? { ...r, enabled } : r)),
    }));
    if (enabled) await invoke<string[]>("run_rule", { ruleId });
  },

  runRule: async (ruleId) => {
    return invoke<string[]>("run_rule", { ruleId });
  },

  runRulesNow: async (folderId) => {
    return invoke<string[]>("run_rules_now", { folderId });
  },

  previewRules: async (folderId) => {
    return invoke<PreviewResult>("preview_rules", { folderId });
  },

  checkForUpdates: async () => {
    set({ updateStatus: "checking" });
    try {
      const currentVersion = await getVersion();
      const update = await check();

      if (!update) {
        set({
          updateStatus: "up-to-date",
          updateInfo: {
            current_version: currentVersion,
            latest_version: currentVersion,
            has_update: false,
            release_url: releaseUrl(currentVersion),
            release_name: `Forel ${currentVersion}`,
          },
          pendingUpdate: null,
        });
        return;
      }

      set({
        updateStatus: "available",
        updateInfo: {
          current_version: update.currentVersion,
          latest_version: update.version,
          has_update: true,
          release_url: releaseUrl(update.version),
          release_name: `Forel ${update.version}`,
        },
        pendingUpdate: update,
      });
    } catch (error) {
      console.error("Failed to check for updates", error);
      set({ updateStatus: "error", pendingUpdate: null });
    }
  },

  installUpdate: async () => {
    const update = get().pendingUpdate;
    if (!update) return;

    set({ updateStatus: "installing" });
    try {
      await update.downloadAndInstall();
      set({ updateStatus: "installed", pendingUpdate: null });
      await relaunch();
    } catch (error) {
      console.error("Failed to install update", error);
      set({ updateStatus: "error" });
    }
  },
}));
