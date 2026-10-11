"""
title: godot-bridge-tool
author: lynn
description: Tool set for the Godot Bridge editor plugin (HTTP JSON API).
version: 2.8.0
requirements: pydantic
"""

import json
import socket
import urllib.error
import urllib.request
from typing import Any, Optional
from pydantic import BaseModel


class Tools:

    class Valves(BaseModel):
        GODOT_HOST: str = "127.0.0.1"
        GODOT_PORT: int = 9090
        AUTH_TOKEN: str = ""
        TIMEOUT_SECONDS: int = 15
        MAX_RESULT_CHARS: int = 12000
        ALLOW_DELETE: bool = False

    def __init__(self):
        self.valves = self.Valves()
        self.citation = False

    def _call(self, command: str, params: Optional[dict] = None) -> str:
        if params is None:
            params = {}

        url = f"http://{self.valves.GODOT_HOST}:{self.valves.GODOT_PORT}/"
        body = json.dumps({"command": command, "payload": params}).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.valves.AUTH_TOKEN:
            headers["Authorization"] = f"Bearer {self.valves.AUTH_TOKEN}"

        req = urllib.request.Request(url, data=body, headers=headers, method="POST")

        try:
            with urllib.request.urlopen(
                req, timeout=float(self.valves.TIMEOUT_SECONDS)
            ) as resp:
                text = resp.read().decode("utf-8", "replace").strip()
        except urllib.error.HTTPError as e:
            text = e.read().decode("utf-8", "replace").strip()
            if not text:
                text = json.dumps({"ok": False, "error": f"HTTP {e.code}"})
        except (socket.timeout, TimeoutError):
            return json.dumps(
                {
                    "ok": False,
                    "error": "Godot Bridge timed out. Verify the server is started in Godot.",
                }
            )
        except urllib.error.URLError as e:
            if isinstance(e.reason, (socket.timeout, TimeoutError)):
                return json.dumps(
                    {
                        "ok": False,
                        "error": "Godot Bridge timed out. Verify the server is started in Godot.",
                    }
                )
            return json.dumps(
                {
                    "ok": False,
                    "error": f"Cannot reach Godot Bridge at {self.valves.GODOT_HOST}:{self.valves.GODOT_PORT} ({e.reason}).",
                }
            )
        except Exception as e:
            return json.dumps({"ok": False, "error": f"Bridge call failed: {e}"})

        limit = self.valves.MAX_RESULT_CHARS
        if len(text) > limit:
            text = text[:limit] + "... [truncated]"
        return text

    @staticmethod
    def _p(**kwargs) -> dict:
        mapping = {"class_name": "class"}
        return {mapping.get(k, k): v for k, v in kwargs.items() if v is not None}

    def _blocked(self, what: str) -> str:
        return json.dumps(
            {
                "ok": False,
                "error": f"{what} is disabled. Enable ALLOW_DELETE in tool settings.",
            }
        )

    # ------------------------------------------------------------------
    # Read-only
    # ------------------------------------------------------------------

    def ping(self) -> str:
        """Check that the Godot Bridge is reachable."""
        return self._call("ping")

    def get_commands(self) -> str:
        """List every bridge command and whether it is enabled."""
        return self._call("get_commands")

    def get_scene_tree(self, max_depth: int = 4) -> str:
        """Get the node tree of the scene open in the editor."""
        return self._call("get_scene_tree", self._p(max_depth=max_depth))

    def get_selected_nodes(self) -> str:
        """Get the nodes currently selected in the editor."""
        return self._call("get_selected_nodes")

    def get_node_properties(
        self, node_path: str, filter_text: Optional[str] = None
    ) -> str:
        """Get editor properties of a node. filter_text matches property names."""
        return self._call(
            "get_node_properties", self._p(node_path=node_path, filter=filter_text)
        )

    def get_node_signals(self, node_path: str, connected_only: bool = False) -> str:
        """Get the signals of a node and what they are connected to."""
        return self._call(
            "get_node_signals",
            self._p(node_path=node_path, connected_only=connected_only),
        )

    def get_open_scenes(self) -> str:
        """List the scene files currently open in the editor."""
        return self._call("get_open_scenes")

    def get_open_script(self) -> str:
        """Get the path and text of the script open in the script editor."""
        return self._call("get_open_script")

    def read_file(self, path: str, offset: int = 0, limit: int = 8000) -> str:
        """Read a project file as text."""
        return self._call("read_file", self._p(path=path, offset=offset, limit=limit))

    def list_dir(self, path: str = "res://") -> str:
        """List files and folders in a project directory."""
        return self._call("list_dir", self._p(path=path))

    def get_output(self, new_only: bool = True) -> str:
        """Read the editor Output panel. new_only returns just what is new since the last call."""
        return self._call("get_output", self._p(new_only=new_only))

    def validate_script(self, path: str) -> str:
        """Check a GDScript file for parse errors. Returns the line number and message.
        Call this after every write_file on a .gd file."""
        return self._call("validate_script", self._p(path=path))

    def class_info(self, class_name: str) -> str:
        """List the methods of a Godot class."""
        return self._call("class_info", self._p(class_name=class_name))

    # ------------------------------------------------------------------
    # Files
    # ------------------------------------------------------------------

    def move_file(self, source: str, target: str) -> str:
        """Move a file from source to target path."""
        return self._call("move_file", self._p(source=source, target=target))

    def copy_file(self, source: str, target: str) -> str:
        """Copy a file from source to target path."""
        return self._call("copy_file", self._p(source=source, target=target))

    def delete_dir(self, path: str) -> str:
        """Delete a directory and all its contents."""
        return self._call("delete_dir", self._p(path=path))

    def write_file(self, path: str, content: str) -> str:
        """Replace the WHOLE file with the given content."""
        return self._call("write_file", self._p(path=path, content=content))

    def make_dir(self, path: str) -> str:
        """Create a directory (and parents) in the project."""
        return self._call("make_dir", self._p(path=path))

    def delete_file(self, path: str) -> str:
        """Delete a project file. Requires ALLOW_DELETE here and delete_file enabled in the Godot dock."""
        if not self.valves.ALLOW_DELETE:
            return self._blocked("delete_file")
        return self._call("delete_file", self._p(path=path))

    # ------------------------------------------------------------------
    # Scene editing
    # ------------------------------------------------------------------

    def spawn_node(
        self,
        node_type: str,
        name: str = "",
        parent: str = "",
        properties_json: str = "{}",
    ) -> str:
        """Add a new node to the open scene. parent is a node path; empty means the scene root."""
        try:
            props = json.loads(properties_json) if properties_json else {}
        except json.JSONDecodeError:
            props = {}
        return self._call(
            "spawn_node",
            self._p(
                node_type=node_type,
                name=name or None,
                parent=parent or None,
                properties=props,
            ),
        )

    def spawn_packed_scene(
        self, scene_path: str, name: str = "", parent: str = ""
    ) -> str:
        """Instance a .tscn file into the open scene."""
        return self._call(
            "spawn_packed_scene",
            self._p(scene_path=scene_path, name=name or None, parent=parent or None),
        )

    def remove_node(self, node_path: str) -> str:
        """Remove a node from the open scene."""
        return self._call("remove_node", self._p(node_path=node_path))

    def rename_node(self, node_path: str, new_name: str) -> str:
        """Rename a node in the open scene."""
        return self._call(
            "rename_node", self._p(node_path=node_path, new_name=new_name)
        )

    def set_node_property(self, node_path: str, property: str, value: Any) -> str:
        """Set one property on a node."""
        return self._call(
            "set_node_property",
            {"node_path": node_path, "property": property, "value": value},
        )

    def attach_script(self, node_path: str, script_path: str) -> str:
        """Attach a script file to a node."""
        return self._call(
            "attach_script", self._p(node_path=node_path, script_path=script_path)
        )

    def add_to_group(self, node_path: str, group: str) -> str:
        """Add a node to a group."""
        return self._call("add_to_group", self._p(node_path=node_path, group=group))

    def connect_signal(self, source: str, target: str, signal: str, method: str) -> str:
        """Connect a signal on the source node to a method on the target node."""
        return self._call(
            "connect_signal",
            self._p(source=source, target=target, signal=signal, method=method),
        )

    # ------------------------------------------------------------------
    # Scene files and running
    # ------------------------------------------------------------------

    def create_scene(self, path: str) -> str:
        """Create a new scene file and open it."""
        return self._call("create_scene", self._p(path=path))

    def save_scene(self) -> str:
        """Save the scene open in the editor."""
        return self._call("save_scene")

    def open_scene(self, path: str) -> str:
        """Open a scene file in the editor."""
        return self._call("open_scene", self._p(path=path))

    def set_main_scene(self, path: str) -> str:
        """Set the project's main scene."""
        return self._call("set_main_scene", self._p(path=path))

    def run_project(self) -> str:
        """Play the project's main scene."""
        return self._call("run_project")

    def run_current_scene(self) -> str:
        """Play the scene currently open in the editor."""
        return self._call("run_current_scene")

    def stop_project(self) -> str:
        """Stop the running game."""
        return self._call("stop_project")