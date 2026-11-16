@tool
extends Node
class_name GodotGitSync

signal progress_update(percent, text)
signal log_msg(msg)
signal sync_finished()

const IGNORE_EXTS = ["import", "tmp", "bak", "godot", "uid"]
const MAX_CONCURRENT = 5

var api: GodotGitApi
var branch = "main"
var head_commit_sha = ""
var head_tree_sha = ""

var atomic_files: Array = []
var blob_results: Dictionary = {}
var pending_blobs = 0
var total_blobs = 0

func setup(a: GodotGitApi):
    api = a
    api.response_received.connect(_on_api_resp)

func start_sync(branch_name: String):
    branch = branch_name
    log_msg.emit("Starting sync to " + branch + "...")
    progress_update.emit(5, "Getting branch info...")
    api.api_get("/branches/" + branch, "sync_branch_info")

func _on_api_resp(tag: String, code: int, text: String, index: int):
    match tag:
        "sync_branch_info":
            if code == 200:
                var json = JSON.parse_string(text)
                head_commit_sha = json["commit"]["sha"]
                head_tree_sha = json["commit"]["commit"]["tree"]["sha"]
                _prepare_files()
            elif code == 404:
                log_msg.emit("Branch not found. Auto-creating from main...")
                api.api_get("/branches/main", "get_main_for_new")
                
        "get_main_for_new":
            var json = JSON.parse_string(text)
            if code == 200 and json and json.has("commit"):
                var main_sha = json["commit"]["sha"]
                var body = JSON.stringify({"ref": "refs/heads/" + branch, "sha": main_sha})
                api.api_post("/git/refs", body, "branch_created")

        "branch_created":
            if code == 201:
                log_msg.emit("Branch created. Retrying sync...")
                api.api_get("/branches/" + branch, "sync_branch_info")
                
        "sync_blob":
            if code == 201:
                var json = JSON.parse_string(text)
                blob_results[atomic_files[index]["path"]] = json["sha"]
                pending_blobs -= 1
                var done = total_blobs - pending_blobs
                progress_update.emit(10 + (done / float(total_blobs)) * 50, "Uploading %d/%d" % [done, total_blobs])
                if index + MAX_CONCURRENT < atomic_files.size():
                    _upload_blob(index + MAX_CONCURRENT)
                if pending_blobs <= 0:
                    _build_tree()

        "sync_tree":
            if code == 201:
                var json = JSON.parse_string(text)
                progress_update.emit(75, "Creating Commit...")
                var body = JSON.stringify({
                    "message": "Atomic sync from Godot",
                    "tree": json["sha"],
                    "parents": [head_commit_sha]
                })
                api.api_post("/git/commits", body, "sync_commit")
                
        "sync_commit":
            if code == 201:
                var json = JSON.parse_string(text)
                progress_update.emit(90, "Updating branch ref...")
                var body = JSON.stringify({"sha": json["sha"], "force": true})
                api.api_patch("/git/refs/heads/" + branch, body, "sync_ref")

        "sync_ref":
            if code == 200:
                log_msg.emit("[color=green]Atomic Sync Success![/color]")
                progress_update.emit(100, "Done")
                sync_finished.emit()

func _prepare_files():
    atomic_files.clear()
    blob_results.clear()
    var paths = []
    _scan("res://", paths)
    for p in paths:
        var rel = p.replace("res://","")
        var f = FileAccess.open(p, FileAccess.READ)
        if f:
            atomic_files.append({"path": rel, "b64": Marshalls.raw_to_base64(f.get_buffer(f.get_length()))})
            f.close()
    
    total_blobs = atomic_files.size()
    pending_blobs = total_blobs
    log_msg.emit("Uploading %d files..." % total_blobs)
    for i in range(mini(MAX_CONCURRENT, atomic_files.size())):
        _upload_blob(i)

func _upload_blob(index: int):
    var body = JSON.stringify({"content": atomic_files[index]["b64"], "encoding": "base64"})
    api.api_post("/git/blobs", body, "sync_blob", index)

func _build_tree():
    var tree_arr = []
    for p in blob_results.keys():
        tree_arr.append({"path": p, "mode": "100644", "type": "blob", "sha": blob_results[p]})
    var body = JSON.stringify({"base_tree": head_tree_sha, "tree": tree_arr})
    progress_update.emit(65, "Creating Tree...")
    api.api_post("/git/trees", body, "sync_tree")

func _scan(path: String, out: Array):
    var d = DirAccess.open(path)
    if not d: return
    d.list_dir_begin()
    var f = d.get_next()
    while f != "":
        if f.begins_with("."):
            f = d.get_next()
            continue
        var full = path.path_join(f)
        if d.current_is_dir(): _scan(full, out)
        else:
            if not f.get_extension() in IGNORE_EXTS: out.append(full)
        f = d.get_next()
    d.list_dir_end()
