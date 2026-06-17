import { History as HistoryIcon, Settings as SettingsIcon } from "lucide-react";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useState } from "react";
import History from "./components/History";
import RuleList from "./components/RuleList";
import Settings from "./components/Settings";
import Sidebar from "./components/Sidebar";
import { useForelStore } from "./store";
import "./store/settings"; // applies the persisted theme on load
import "./App.css";

export default function App() {
  const fetchFolders = useForelStore((s) => s.fetchFolders);
  const checkForUpdates = useForelStore((s) => s.checkForUpdates);
  const [showSettings, setShowSettings] = useState(false);
  const [showHistory, setShowHistory] = useState(false);

  useEffect(() => {
    void fetchFolders();
  }, [fetchFolders]);

  useEffect(() => {
    void checkForUpdates();
    const id = setInterval(() => void checkForUpdates(), 4 * 60 * 60 * 1000);
    return () => clearInterval(id);
  }, [checkForUpdates]);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    void listen("tray:check-updates", () => {
      setShowSettings(true);
      void checkForUpdates();
    }).then((cleanup) => {
      unlisten = cleanup;
    });

    return () => unlisten?.();
  }, [checkForUpdates]);

  // ⌘, opens Settings, like a native macOS app.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey && e.key === ",") {
        e.preventDefault();
        setShowSettings(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="app">
      <div className="titlebar" data-tauri-drag-region>
        <div className="titlebar-brand">
          <img className="titlebar-icon" src="/forel-icon.png" alt="" />
          <span className="titlebar-title">Forel</span>
        </div>
        <div className="titlebar-actions">
          <button
            className="titlebar-btn"
            onClick={() => setShowHistory(true)}
            title="Activity"
          >
            <HistoryIcon size={15} />
          </button>
          <button
            className="titlebar-btn"
            onClick={() => setShowSettings(true)}
            title="Settings (⌘,)"
          >
            <SettingsIcon size={15} />
          </button>
        </div>
      </div>

      <div className="layout">
        <Sidebar />
        <RuleList />
      </div>

      {showHistory && <History onClose={() => setShowHistory(false)} />}
      {showSettings && (
        <Settings
          onClose={() => setShowSettings(false)}
          onOpenHistory={() => {
            setShowSettings(false);
            setShowHistory(true);
          }}
        />
      )}
    </div>
  );
}
