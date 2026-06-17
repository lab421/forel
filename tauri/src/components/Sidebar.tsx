import { open } from "@tauri-apps/plugin-dialog";
import { Folder, Minus, Plus } from "lucide-react";
import { useForelStore } from "../store";
import { WatchedFolder } from "../types";

export default function Sidebar() {
  const { folders, selectedFolderId, selectFolder, addFolder, removeFolder } =
    useForelStore();

  const handleAdd = async () => {
    const selected = await open({ directory: true, multiple: false });
    if (typeof selected === "string") {
      await addFolder(selected);
    }
  };

  const handleRemove = () => {
    if (selectedFolderId) void removeFolder(selectedFolderId);
  };

  return (
    <aside className="sidebar">
      <div className="sidebar-header">Folders</div>

      <ul className="folder-list">
        {folders.map((folder) => (
          <FolderItem
            key={folder.id}
            folder={folder}
            selected={folder.id === selectedFolderId}
            onSelect={() => selectFolder(folder.id)}
          />
        ))}
        {folders.length === 0 && (
          <li className="folder-empty">No folders — click + to add one</li>
        )}
      </ul>

      <div className="sidebar-toolbar">
        <button
          className="toolbar-btn"
          onClick={handleAdd}
          title="Add folder"
        >
          <Plus size={14} />
        </button>
        <button
          className="toolbar-btn"
          onClick={handleRemove}
          disabled={!selectedFolderId}
          title="Remove folder"
        >
          <Minus size={14} />
        </button>
      </div>
    </aside>
  );
}

function FolderItem({
  folder,
  selected,
  onSelect,
}: {
  folder: WatchedFolder;
  selected: boolean;
  onSelect: () => void;
}) {
  const name = folder.path.split("/").pop() ?? folder.path;

  return (
    <li
      className={`folder-item ${selected ? "selected" : ""} ${!folder.enabled ? "disabled" : ""}`}
      onClick={onSelect}
    >
      <Folder size={15} className="folder-icon" />
      <span className="folder-name" title={folder.path}>
        {name}
      </span>
    </li>
  );
}
