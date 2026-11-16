@tool
extends EditorPlugin

const GitDock = preload("res://addons/godot-git-plugin/gui/git_dock.gd")

var dock

func _enter_tree():
    var dock_content = GitDock.new()
    dock = EditorDock.new()
    dock.title = "GitUploader"
    dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
    dock.add_child(dock_content)
    add_dock(dock)

func _exit_tree():
    if dock:
        remove_dock(dock)
        dock.queue_free()
        dock = null
