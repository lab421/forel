import { Download, ExternalLink, Monitor, Moon, RefreshCw, Sun, X } from "lucide-react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useForelStore } from "../store";
import { Theme, useSettings } from "../store/settings";
import { UpdateStatus } from "../types";

const THEME_OPTIONS: { value: Theme; label: string; icon: typeof Sun }[] = [
  { value: "system", label: "System", icon: Monitor },
  { value: "light", label: "Light", icon: Sun },
  { value: "dark", label: "Dark", icon: Moon },
];

function updateLabel(status: UpdateStatus) {
  switch (status) {
    case "checking":
      return "Checking...";
    case "up-to-date":
      return "Forel is up to date.";
    case "available":
      return "A new version is available.";
    case "installing":
      return "Installing...";
    case "installed":
      return "Installed. Relaunching...";
    case "error":
      return "Could not check for updates.";
    default:
      return "No update check yet.";
  }
}

export default function Settings({ onClose }: { onClose: () => void }) {
  const { theme, setTheme } = useSettings();
  const updateStatus = useForelStore((s) => s.updateStatus);
  const updateInfo = useForelStore((s) => s.updateInfo);
  const checkForUpdates = useForelStore((s) => s.checkForUpdates);
  const installUpdate = useForelStore((s) => s.installUpdate);
  const busy = updateStatus === "checking" || updateStatus === "installing";

  return (
    <div
      className="editor-overlay"
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <div className="settings-panel">
        <header className="settings-header">
          <h2 className="settings-title">Settings</h2>
          <button className="editor-close" onClick={onClose} title="Close">
            <X size={16} />
          </button>
        </header>

        <section className="settings-section">
          <div className="settings-row">
            <div className="settings-label">
              <span className="settings-label-title">Appearance</span>
              <span className="settings-label-sub">
                Match the system or pick a fixed theme.
              </span>
            </div>
            <div className="segmented">
              {THEME_OPTIONS.map(({ value, label, icon: Icon }) => (
                <button
                  key={value}
                  className={`segmented-option${theme === value ? " active" : ""}`}
                  onClick={() => setTheme(value)}
                  title={label}
                >
                  <Icon size={13} />
                  <span>{label}</span>
                </button>
              ))}
            </div>
          </div>
        </section>

        <section className="settings-section">
          <div className="settings-row settings-update-row">
            <div className="settings-label">
              <span className="settings-label-title">Updates</span>
              <span className="settings-label-sub">{updateLabel(updateStatus)}</span>
              {updateInfo?.has_update && (
                <span className="settings-label-sub">
                  {updateInfo.current_version} to {updateInfo.latest_version}
                </span>
              )}
            </div>
            <div className="settings-update-actions">
              {updateInfo?.has_update && (
                <button
                  className="settings-update-btn primary"
                  onClick={() => void installUpdate()}
                  disabled={busy}
                >
                  <Download size={13} />
                  <span>Install</span>
                </button>
              )}
              {updateInfo?.release_url && (
                <button
                  className="settings-icon-btn"
                  onClick={() => void openUrl(updateInfo.release_url)}
                  title="Open release"
                >
                  <ExternalLink size={14} />
                </button>
              )}
              <button
                className="settings-update-btn"
                onClick={() => void checkForUpdates()}
                disabled={busy}
              >
                <RefreshCw
                  size={13}
                  className={busy ? "spinning" : undefined}
                />
                <span>Check</span>
              </button>
            </div>
          </div>
        </section>

        <section className="settings-section">
          <div className="settings-about">
            <span className="settings-about-name">Forel</span>
            <span className="settings-about-version">Version 0.1.0 · alpha</span>
            <span className="settings-about-desc">
              Open-source file automation for macOS.
            </span>
          </div>
        </section>
      </div>
    </div>
  );
}
