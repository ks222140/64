@tool
extends VBoxContainer

const CONFIG_PATH = "user://godot_git_config.cfg"
const STATE_PATH = "user://godot_git_state.json"
const BACKUP_DIR = "user://godot_git_backups/"
const IGNORE_EXTS = ["import", "tmp", "bak", "godot", "uid"]
const MAX_CONCURRENT = 5

var token_edit: LineEdit
var owner_edit: LineEdit
var repo_edit: LineEdit
var branch_edit: LineEdit
var log_label: RichTextLabel
var file_tree: Tree
var file_root: TreeItem
var progress_bar: ProgressBar
var status_label: Label

var local_state: Dictionary = {}
var remote_state: Dictionary = {}

var diff_window: Window
var diff_left: RichTextLabel
var diff_right: RichTextLabel

# 原子上传状态
var atomic_files: Array = []
var blob_results: Dictionary = {}
var pending_blobs = 0
var total_blobs = 0
var head_commit_sha = ""
var head_tree_sha = ""
var release_id = 0
var pending_apk_path = ""
var temp_path = ""

func _ready():
    _build_ui()
    _create_diff_window()
    _load_config()
    _load_state()
    _refresh_file_list()
    DirAccess.make_dir_recursive_absolute(BACKUP_DIR)

func _build_ui():
    var title = Label.new()
    title.text = "Godot 纯 API Git 客户端"
    title.add_theme_color_override("font_color", Color(0.4,0.8,1))
    add_child(title)

    token_edit = LineEdit.new()
    token_edit.placeholder_text = "Token (PAT)"
    token_edit.secret = true
    add_child(token_edit)

    var h1 = HBoxContainer.new()
    owner_edit = LineEdit.new()
    owner_edit.placeholder_text = "用户名"
    owner_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    h1.add_child(owner_edit)
    repo_edit = LineEdit.new()
    repo_edit.placeholder_text = "仓库名"
    repo_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    h1.add_child(repo_edit)
    add_child(h1)

    var h2 = HBoxContainer.new()
    branch_edit = LineEdit.new()
    branch_edit.placeholder_text = "分支"
    branch_edit.text = "main"
    branch_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    h2.add_child(branch_edit)
    var btn_refresh = Button.new()
    btn_refresh.text = "刷新远程"
    btn_refresh.pressed.connect(_fetch_remote_tree)
    h2.add_child(btn_refresh)
    add_child(h2)

    var save_btn = Button.new()
    save_btn.text = "保存配置"
    save_btn.pressed.connect(_save_config)
    add_child(save_btn)

    progress_bar = ProgressBar.new()
    progress_bar.custom_minimum_size = Vector2(0, 20)
    progress_bar.max_value = 100
    progress_bar.value = 0
    add_child(progress_bar)
    
    status_label = Label.new()
    status_label.text = "就绪"
    add_child(status_label)

    file_tree = Tree.new()
    file_tree.custom_minimum_size = Vector2(0, 200)
    file_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
    file_tree.hide_root = true
    file_tree.columns = 2
    file_tree.set_column_title(0, "文件")
    file_tree.set_column_title(1, "状态")
    file_tree.column_titles_visible = true
    add_child(file_tree)

    var hbox_actions = HBoxContainer.new()
    var btn_pull = Button.new()
    btn_pull.text = "拉取选中"
    btn_pull.pressed.connect(_pull_selected)
    hbox_actions.add_child(btn_pull)
    var btn_diff = Button.new()
    btn_diff.text = "本地 Diff"
    btn_diff.pressed.connect(_show_local_diff)
    hbox_actions.add_child(btn_diff)
    var btn_sync = Button.new()
    btn_sync.text = "一键原子同步"
    btn_sync.pressed.connect(_push_atomic)
    hbox_actions.add_child(btn_sync)
    add_child(hbox_actions)

    var hbox_adv = HBoxContainer.new()
    var btn_backup = Button.new()
    btn_backup.text = "创建快照"
    btn_backup.pressed.connect(_create_local_backup)
    hbox_adv.add_child(btn_backup)
    var btn_hist = Button.new()
    btn_hist.text = "历史记录"
    btn_hist.pressed.connect(_show_commit_history)
    hbox_adv.add_child(btn_hist)
    var btn_release = Button.new()
    btn_release.text = "发布 Release (APK)"
    btn_release.pressed.connect(_publish_release)
    hbox_adv.add_child(btn_release)
    add_child(hbox_adv)

    log_label = RichTextLabel.new()
    log_label.custom_minimum_size = Vector2(0, 120)
    log_label.scroll_following = true
    log_label.bbcode_enabled = true
    add_child(log_label)

func _create_diff_window():
    diff_window = Window.new()
    diff_window.title = "本地 Diff"
    diff_window.size = Vector2i(1000, 700)
    diff_window.visible = false
    diff_window.transient = true
    var vbox = VBoxContainer.new()
    vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    diff_window.add_child(vbox)
    var split = HSplitContainer.new()
    split.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vbox.add_child(split)
    var lb = VBoxContainer.new()
    lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    var ll = Label.new()
    ll.text = "远程"
    ll.add_theme_color_override("font_color", Color(0.9,0.4,0.4))
    lb.add_child(ll)
    diff_left = RichTextLabel.new()
    diff_left.size_flags_vertical = Control.SIZE_EXPAND_FILL
    diff_left.bbcode_enabled = true
    lb.add_child(diff_left)
    split.add_child(lb)
    var rb = VBoxContainer.new()
    rb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    var rl = Label.new()
    rl.text = "本地"
    rl.add_theme_color_override("font_color", Color(0.3,0.8,0.3))
    rb.add_child(rl)
    diff_right = RichTextLabel.new()
    diff_right.size_flags_vertical = Control.SIZE_EXPAND_FILL
    diff_right.bbcode_enabled = true
    rb.add_child(diff_right)
    split.add_child(rb)
    var close = Button.new()
    close.text = "关闭"
    close.pressed.connect(func(): diff_window.hide())
    vbox.add_child(close)
    add_child(diff_window)

# ============ 核心：获取分支信息 ============
# 修复：之前直接把 main 当成 tree sha 去请求，导致 404。
# 正确做法：先请求 branches/main 拿到 commit sha 和 tree sha。
func _fetch_remote_tree():
    _set_progress(10, "获取分支信息...")
    if branch_edit.text.strip_edges() == "": branch_edit.text = "main"
    var url = "https://api.github.com/repos/%s/%s/branches/%s" % [owner_edit.text, repo_edit.text, branch_edit.text]
    _api_get(url, "refresh_branch_info")

func _fetch_actual_tree():
    _set_progress(30, "获取远程文件树...")
    var url = "https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1" % [owner_edit.text, repo_edit.text, head_tree_sha]
    _api_get(url, "refresh_tree")

func _refresh_file_list():
    file_tree.clear()
    file_root = file_tree.create_item()
    var paths = []
    _scan_local("res://", paths)
    for p in paths:
        var rel = p.replace("res://","")
        var sha = FileAccess.get_file_as_string(p).sha256_text()
        var st = "OK"
        if local_state.has(rel):
            if local_state[rel] != sha: st = "M"
        else:
            st = "U"
        local_state[rel] = sha
        var item = file_tree.create_item(file_root)
        item.set_text(0, rel)
        item.set_text(1, st)
        match st:
            "M": item.set_custom_color(1, Color(0.9,0.7,0.3))
            "U": item.set_custom_color(1, Color(0.3,0.8,0.3))
        item.set_metadata(0, {"path": rel, "status": st})
    _save_state()

func _scan_local(path: String, out: Array):
    var d = DirAccess.open(path)
    if not d: return
    d.list_dir_begin()
    var f = d.get_next()
    while f != "":
        if f.begins_with("."):
            f = d.get_next()
            continue
        var full = path.path_join(f)
        if d.current_is_dir(): _scan_local(full, out)
        else:
            if not f.get_extension() in IGNORE_EXTS: out.append(full)
        f = d.get_next()
    d.list_dir_end()

# ============ 原子上传 ============
func _push_atomic():
    if atomic_files.size() > 0: return
    _log("开始原子同步...")
    _set_progress(5, "获取分支信息...")
    if branch_edit.text.strip_edges() == "": branch_edit.text = "main"
    var url = "https://api.github.com/repos/%s/%s/branches/%s" % [owner_edit.text, repo_edit.text, branch_edit.text]
    _api_get(url, "atomic_branch_info")

func _prepare_atomic_files():
    atomic_files.clear()
    blob_results.clear()
    var paths = []
    _scan_local("res://", paths)
    for p in paths:
        var rel = p.replace("res://","")
        var f = FileAccess.open(p, FileAccess.READ)
        if f == null: continue
        var b64 = Marshalls.raw_to_base64(f.get_buffer(f.get_length()))
        f.close()
        atomic_files.append({"path": rel, "b64": b64})
    total_blobs = atomic_files.size()
    pending_blobs = total_blobs
    _log("开始上传 %d 个 Blob..." % total_blobs)
    _set_progress(10, "上传 Blob 0/%d" % total_blobs)
    for i in range(mini(MAX_CONCURRENT, atomic_files.size())):
        _create_blob(i)

func _create_blob(index: int):
    if index >= atomic_files.size(): return
    var body = JSON.stringify({"content": atomic_files[index]["b64"], "encoding": "base64"})
    _api_post("https://api.github.com/repos/%s/%s/git/blobs" % [owner_edit.text, repo_edit.text],
        body, "blob", index)

func _on_blob_done(code, body, index):
    if code == 201:
        var json = JSON.parse_string(body)
        if json and json.has("sha"):
            blob_results[atomic_files[index]["path"]] = json["sha"]
            pending_blobs -= 1
            var done = total_blobs - pending_blobs
            _set_progress(10 + (done / float(total_blobs)) * 50, "上传 Blob %d/%d" % [done, total_blobs])
            var next_idx = index + MAX_CONCURRENT
            if next_idx < atomic_files.size(): _create_blob(next_idx)
            if pending_blobs <= 0: _build_tree()
        else:
            _log("[color=red]Blob 失败: " + atomic_files[index]["path"] + "[/color]")
    else:
        _log("[color=red]Blob HTTP " + str(code) + "[/color]")

func _build_tree():
    var tree_arr = []
    for path in blob_results.keys():
        tree_arr.append({"path": path, "mode": "100644", "type": "blob", "sha": blob_results[path]})
    var body = JSON.stringify({"base_tree": head_tree_sha, "tree": tree_arr})
    _log("构建 Tree，共 %d 个文件..." % tree_arr.size())
    _set_progress(65, "创建 Tree...")
    _api_post("https://api.github.com/repos/%s/%s/git/trees" % [owner_edit.text, repo_edit.text],
        body, "tree", -1)

# ============ 统一请求封装 ============
func _api_get(url: String, tag: String):
    var req = HTTPRequest.new()
    add_child(req)
    req.request_completed.connect(func(r, c, h, b): _handle_response(r, c, h, b, tag); req.queue_free())
    req.request(url, _headers(), HTTPClient.METHOD_GET)

func _api_post(url: String, body: String, tag: String, index: int):
    var req = HTTPRequest.new()
    add_child(req)
    req.request_completed.connect(func(r, c, h, b): _handle_response(r, c, h, b, tag, index); req.queue_free())
    req.request(url, _headers(), HTTPClient.METHOD_POST, body)

# ============ HTTP 响应处理 ============
func _handle_response(result, code, headers, body, tag: String, index: int = -1):
    if result != HTTPRequest.RESULT_SUCCESS:
        _log("[color=red]网络错误: " + str(result) + "[/color]")
        return
    var text = body.get_string_from_utf8()

    match tag:
        "refresh_branch_info":
            var json = JSON.parse_string(text)
            if json and json.has("commit"):
                head_tree_sha = json["commit"]["commit"]["tree"]["sha"]
                _fetch_actual_tree()
            else:
                _log("[color=red]获取分支失败: " + text + "[/color]")

        "refresh_tree":
            var json = JSON.parse_string(text)
            if json and json.has("tree"):
                remote_state.clear()
                for item in json["tree"]:
                    if item["type"] == "blob":
                        remote_state[item["path"]] = item["sha"]
                _refresh_file_list()
                _log("远程状态已更新，共 %d 个文件" % remote_state.size())
                _set_progress(100, "刷新完成")
            else:
                _log("[color=red]刷新失败: " + text + "[/color]")

        "atomic_branch_info":
            var json = JSON.parse_string(text)
            if json and json.has("commit"):
                head_commit_sha = json["commit"]["sha"]
                head_tree_sha = json["commit"]["commit"]["tree"]["sha"]
                _log("HEAD: " + head_commit_sha.substr(0,7))
                _prepare_atomic_files()
            else:
                _log("[color=red]获取分支失败: " + text + "[/color]")

        "blob":
            _on_blob_done(code, text, index)

        "tree":
            var json = JSON.parse_string(text)
            if json and json.has("sha"):
                _log("Tree 创建成功，开始 Commit...")
                _set_progress(75, "创建 Commit...")
                var body2 = JSON.stringify({
                    "message": "Atomic sync from Godot",
                    "tree": json["sha"],
                    "parents": [head_commit_sha]
                })
                _api_post("https://api.github.com/repos/%s/%s/git/commits" % [owner_edit.text, repo_edit.text],
                    body2, "commit", -1)
            else:
                _log("[color=red]Tree 创建失败: " + text + "[/color]")

        "commit":
            var json = JSON.parse_string(text)
            if json and json.has("sha"):
                _log("Commit: " + json["sha"].substr(0,7) + "，更新分支...")
                _set_progress(90, "更新分支...")
                var body3 = JSON.stringify({"sha": json["sha"], "force": true})
                var req = HTTPRequest.new()
                add_child(req)
                req.request_completed.connect(func(r, c, h, b):
                    req.queue_free()
                    if c == 200:
                        _log("[color=green]✅ 原子提交完成！[/color]")
                        _set_progress(100, "完成")
                        atomic_files.clear()
                        _refresh_file_list()
                    else:
                        _log("[color=red]更新分支失败: " + b.get_string_from_utf8().substr(0,200) + "[/color]")
                )
                req.request("https://api.github.com/repos/%s/%s/git/refs/heads/%s" % [owner_edit.text, repo_edit.text, branch_edit.text],
                    _headers(), HTTPClient.METHOD_PATCH, body3)
            else:
                _log("[color=red]Commit 失败: " + text + "[/color]")

        "pull_file":
            var json = JSON.parse_string(text)
            if json and json.has("content"):
                var data = Marshalls.base64_to_raw(json["content"].replace("\n", ""))
                var f = FileAccess.open("res://" + temp_path, FileAccess.WRITE)
                f.store_buffer(data)
                f.close()
                _log("[color=green]拉取成功: " + temp_path + "[/color]")
                EditorInterface.get_resource_filesystem().scan()
                _refresh_file_list()
                _set_progress(100, "拉取完成")
            else:
                _log("[color=red]拉取失败[/color]")

# ============ 补齐缺失的辅助函数 ============

func _save_config():
    var cfg = ConfigFile.new()
    cfg.set_value("github","token",token_edit.text)
    cfg.set_value("github","owner",owner_edit.text)
    cfg.set_value("github","repo",repo_edit.text)
    cfg.set_value("github","branch",branch_edit.text)
    cfg.save(CONFIG_PATH)
    _log("配置已保存")

func _load_config():
    var cfg = ConfigFile.new()
    if cfg.load(CONFIG_PATH) != OK: return
    token_edit.text = cfg.get_value("github","token","")
    owner_edit.text = cfg.get_value("github","owner","")
    repo_edit.text = cfg.get_value("github","repo","")
    branch_edit.text = cfg.get_value("github","branch","main")

func _load_state():
    if FileAccess.file_exists(STATE_PATH):
        var s = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
        if s is Dictionary: local_state = s

func _save_state():
    var f = FileAccess.open(STATE_PATH, FileAccess.WRITE)
    f.store_string(JSON.stringify(local_state))
    f.close()

func _log(msg): 
    log_label.append_text(msg + "\n")

func _set_progress(value: float, text: String):
    progress_bar.value = value
    status_label.text = text

func _headers() -> PackedStringArray:
    return PackedStringArray([
        "Authorization: Bearer " + token_edit.text,
        "Accept: application/vnd.github+json",
        "User-Agent: Godot-Git-Client"
    ])

func _pull_selected():
    var item = file_tree.get_selected()
    if item == null: return
    var info = item.get_metadata(0)
    if info.is_empty(): return
    temp_path = info["path"]
    var url = "https://api.github.com/repos/%s/%s/contents/%s?ref=%s" % [owner_edit.text, repo_edit.text, temp_path, branch_edit.text]
    _set_progress(30, "拉取: " + temp_path)
    _api_get(url, "pull_file")

func _show_local_diff():
    var item = file_tree.get_selected()
    if item == null: return
    var info = item.get_metadata(0)
    if info.is_empty(): return
    temp_path = info["path"]
    diff_window.show()
    diff_left.text = "加载中..."
    diff_right.text = "加载中..."
    var url = "https://api.github.com/repos/%s/%s/contents/%s?ref=%s" % [owner_edit.text, repo_edit.text, temp_path, branch_edit.text]
    var req = HTTPRequest.new()
    add_child(req)
    req.request_completed.connect(_on_diff_done)
    req.request(url, _headers(), HTTPClient.METHOD_GET)

func _on_diff_done(result, code, headers, body):
    if code != 200:
        diff_left.text = "远程不存在"
        return
    var json = JSON.parse_string(body.get_string_from_utf8())
    if json == null or not json.has("content"):
        diff_left.text = "解析失败"
        return
    var remote_text = Marshalls.base64_to_raw(json["content"].replace("\n","")).get_string_from_utf8()
    var local_path = "res://" + temp_path
    var local_text = FileAccess.get_file_as_string(local_path) if FileAccess.file_exists(local_path) else ""
    var left_bb = ""
    var right_bb = ""
    var ll = remote_text.split("\n")
    var rl = local_text.split("\n")
    var maxn = max(ll.size(), rl.size())
    for i in range(maxn):
        var l = ll[i] if i < ll.size() else ""
        var r = rl[i] if i < rl.size() else ""
        if l == r:
            left_bb += l + "\n"
            right_bb += r + "\n"
        else:
            left_bb += "[color=red]" + l + "[/color]\n"
            right_bb += "[color=green]" + r + "[/color]\n"
    diff_left.text = left_bb
    diff_right.text = right_bb

func _create_local_backup():
    var time = Time.get_datetime_dict_from_system()
    var stamp = "%02d%02d_%02d%02d%02d" % [time.month, time.day, time.hour, time.minute, time.second]
    var bp = BACKUP_DIR + "snapshot_" + stamp + "/"
    DirAccess.make_dir_recursive_absolute(bp)
    var files = []
    _scan_local("res://", files)
    for f in files:
        var rel = f.replace("res://", "")
        var dst = bp + rel
        DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
        DirAccess.copy_absolute(f, dst)
    _log("[color=cyan]快照创建: " + bp + "[/color]")

func _show_commit_history():
    var url = "https://api.github.com/repos/%s/%s/commits?per_page=10" % [owner_edit.text, repo_edit.text]
    _set_progress(30, "拉取提交历史...")
    _api_get(url, "history")

func _publish_release():
    var fd = FileDialog.new()
    fd.access = FileDialog.ACCESS_FILESYSTEM
    fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    add_child(fd)
    fd.file_selected.connect(func(path):
        _log("创建 Release...")
        pending_apk_path = path
        var body = JSON.stringify({
            "tag_name": "v" + Time.get_datetime_string_from_system().replace(":","-"),
            "name": "Godot Build",
            "body": "Auto release from Godot"
        })
        _set_progress(20, "创建 Release...")
        _api_post("https://api.github.com/repos/%s/%s/releases" % [owner_edit.text, repo_edit.text],
            body, "release", -1)
        fd.queue_free()
    )
    fd.canceled.connect(func(): fd.queue_free())
    fd.popup_centered_ratio(0.7)

func _upload_apk(path):
    _log("上传 APK: " + path)
    var f = FileAccess.open(path, FileAccess.READ)
    var bytes = f.get_buffer(f.get_length())
    f.close()
    var url = "https://uploads.github.com/repos/%s/%s/releases/%d/assets?name=%s" % [
        owner_edit.text, repo_edit.text, release_id, path.get_file()
    ]
    var req = HTTPRequest.new()
    add_child(req)
    req.request_completed.connect(func(r, c, h, b):
        if c == 201:
            _log("[color=green]✅ APK 上传成功！[/color]")
            _set_progress(100, "完成")
        else:
            _log("[color=red]APK 上传失败: " + str(c) + "[/color]")
        req.queue_free()
    )
    _set_progress(60, "上传 APK...")
    req.request_raw(url, PackedStringArray([
        "Authorization: Bearer " + token_edit.text,
        "Content-Type: application/octet-stream",
        "User-Agent: Godot-Git-Client"
    ]), HTTPClient.METHOD_POST, bytes)
