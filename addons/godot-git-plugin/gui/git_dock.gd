@tool
extends VBoxContainer

const CONFIG_PATH = "user://godot_git_config.cfg"
const STATE_PATH = "user://godot_git_state.json"
const BACKUP_DIR = "user://godot_git_backups/"
const IGNORE_EXTS = ["import", "tmp", "bak", "godot", "uid"]

const ApiScript = preload("res://addons/godot-git-plugin/gui/api_client.gd")
const SyncScript = preload("res://addons/godot-git-plugin/gui/sync_manager.gd")

var api: GodotGitApi
var sync_mgr: GodotGitSync

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

var history_window: Window
var graph_control: Control
var history_files_label: RichTextLabel
var commit_history_data = []
var selected_commit_idx = -1

var release_id = 0
var pending_apk_path = ""
var temp_path = ""
var head_commit_sha = ""
var head_tree_sha = ""

func _ready():
    api = ApiScript.new()
    add_child(api)
    
    sync_mgr = SyncScript.new()
    add_child(sync_mgr)
    
    # 强制断开再重连，绝对不让它报红字
    if api.response_received.is_connected(_on_api_resp):
        api.response_received.disconnect(_on_api_resp)
    api.response_received.connect(_on_api_resp)
    
    if sync_mgr.progress_update.is_connected(_set_progress):
        sync_mgr.progress_update.disconnect(_set_progress)
    sync_mgr.progress_update.connect(_set_progress)
    
    if sync_mgr.log_msg.is_connected(_log):
        sync_mgr.log_msg.disconnect(_log)
    sync_mgr.log_msg.connect(_log)
    
    if sync_mgr.sync_finished.is_connected(_on_sync_finished):
        sync_mgr.sync_finished.disconnect(_on_sync_finished)
    sync_mgr.sync_finished.connect(_on_sync_finished)
    
    _build_ui()
    _create_diff_window()
    _create_history_window()
    _load_config()
    _load_state()
    _refresh_file_list()
    DirAccess.make_dir_recursive_absolute(BACKUP_DIR)

func _build_ui():
    var scroll = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    add_child(scroll)
    
    var main_vbox = VBoxContainer.new()
    main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(main_vbox)

    var title = Label.new()
    title.text = "Godot Git Pro"
    title.add_theme_color_override("font_color", Color(0.4,0.8,1))
    main_vbox.add_child(title)

    token_edit = LineEdit.new()
    token_edit.placeholder_text = "Token (PAT)"
    token_edit.secret = true
    main_vbox.add_child(token_edit)

    var h1 = HBoxContainer.new()
    owner_edit = LineEdit.new()
    owner_edit.placeholder_text = "Owner"
    owner_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    h1.add_child(owner_edit)
    repo_edit = LineEdit.new()
    repo_edit.placeholder_text = "Repo"
    repo_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    h1.add_child(repo_edit)
    main_vbox.add_child(h1)

    var h2 = HBoxContainer.new()
    branch_edit = LineEdit.new()
    branch_edit.placeholder_text = "Branch (main)"
    branch_edit.text = "main"
    branch_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    h2.add_child(branch_edit)
    var btn_refresh = Button.new()
    btn_refresh.text = "抓取"
    btn_refresh.pressed.connect(_fetch_remote_tree)
    h2.add_child(btn_refresh)
    main_vbox.add_child(h2)

    var save_btn = Button.new()
    save_btn.text = "保存"
    save_btn.pressed.connect(_save_config)
    main_vbox.add_child(save_btn)

    progress_bar = ProgressBar.new()
    progress_bar.custom_minimum_size = Vector2(0, 20)
    progress_bar.max_value = 100
    progress_bar.value = 0
    main_vbox.add_child(progress_bar)
    
    status_label = Label.new()
    status_label.text = "Ready"
    main_vbox.add_child(status_label)

    file_tree = Tree.new()
    file_tree.custom_minimum_size = Vector2(0, 150)
    file_tree.hide_root = true
    file_tree.columns = 2
    file_tree.set_column_title(0, "File")
    file_tree.set_column_title(1, "Status")
    file_tree.column_titles_visible = true
    main_vbox.add_child(file_tree)

    var hbox_actions = HBoxContainer.new()
    var btn_pull = Button.new()
    btn_pull.text = "拉取"
    btn_pull.pressed.connect(_pull_selected)
    hbox_actions.add_child(btn_pull)
    var btn_diff = Button.new()
    btn_diff.text = "Diff"
    btn_diff.pressed.connect(_show_local_diff)
    hbox_actions.add_child(btn_diff)
    var btn_sync = Button.new()
    btn_sync.text = "同步"
    btn_sync.pressed.connect(_push_atomic)
    hbox_actions.add_child(btn_sync)
    main_vbox.add_child(hbox_actions)

    var hbox_adv = HBoxContainer.new()
    var btn_backup = Button.new()
    btn_backup.text = "Backup"
    btn_backup.pressed.connect(_create_local_backup)
    hbox_adv.add_child(btn_backup)
    var btn_hist = Button.new()
    btn_hist.text = "Graph"
    btn_hist.pressed.connect(_show_commit_history)
    hbox_adv.add_child(btn_hist)
    var btn_release = Button.new()
    btn_release.text = "发布"
    btn_release.pressed.connect(_publish_release)
    hbox_adv.add_child(btn_release)
    main_vbox.add_child(hbox_adv)
    
    var hbox_collab = HBoxContainer.new()
    var btn_pr = Button.new()
    btn_pr.text = "发起 PR"
    btn_pr.pressed.connect(_create_pull_request)
    hbox_collab.add_child(btn_pr)
    var btn_issue = Button.new()
    btn_issue.text = "查看 Issues"
    btn_issue.pressed.connect(_show_issues)
    hbox_collab.add_child(btn_issue)
    var btn_action = Button.new()
    btn_action.text = "触发云编译"
    btn_action.pressed.connect(_trigger_action)
    hbox_collab.add_child(btn_action)
    main_vbox.add_child(hbox_collab)

    var hbox_log = HBoxContainer.new()
    var log_title = Label.new()
    log_title.text = "日志 (Log):"
    log_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hbox_log.add_child(log_title)
    
    var btn_copy = Button.new()
    btn_copy.text = "复制全部"
    btn_copy.pressed.connect(_copy_log)
    hbox_log.add_child(btn_copy)
    
    var btn_clear = Button.new()
    btn_clear.text = "清除日志"
    btn_clear.pressed.connect(_clear_log)
    hbox_log.add_child(btn_clear)
    
    main_vbox.add_child(hbox_log)

    log_label = RichTextLabel.new()
    log_label.custom_minimum_size = Vector2(0, 150)
    log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
    log_label.scroll_following = true
    log_label.bbcode_enabled = true
    main_vbox.add_child(log_label)

func _copy_log():
    DisplayServer.clipboard_set(log_label.get_parsed_text())
    _log("[color=cyan]日志已复制到剪贴板[/color]")

func _clear_log():
    log_label.clear()
    _log("[color=cyan]日志已清空[/color]")

func _set_progress(value: float, text: String):
    progress_bar.value = value
    status_label.text = text

func _log(msg): log_label.append_text(msg + "\n")

func _save_config():
    var cfg = ConfigFile.new()
    cfg.set_value("github","token",token_edit.text)
    cfg.set_value("github","owner",owner_edit.text)
    cfg.set_value("github","repo",repo_edit.text)
    cfg.set_value("github","branch",branch_edit.text)
    cfg.save(CONFIG_PATH)
    _log("Config saved")
    _setup_api()

func _load_config():
    var cfg = ConfigFile.new()
    if cfg.load(CONFIG_PATH) != OK: return
    token_edit.text = cfg.get_value("github","token","")
    owner_edit.text = cfg.get_value("github","owner","")
    repo_edit.text = cfg.get_value("github","repo","")
    branch_edit.text = cfg.get_value("github","branch","main")
    _setup_api()

func _setup_api():
    api.setup(token_edit.text, owner_edit.text, repo_edit.text)
    sync_mgr.setup(api)

func _on_sync_finished():
    _refresh_file_list()
    _set_progress(100, "Done")

func _push_atomic():
    _setup_api()
    if branch_edit.text.strip_edges() == "": branch_edit.text = "main"
    sync_mgr.start_sync(branch_edit.text)

# ============ 核心抓取逻辑（带超时监控） ============
func _fetch_remote_tree():
    _setup_api()
    if branch_edit.text.strip_edges() == "": branch_edit.text = "main"
    _set_progress(10, "Getting branch info...")
    _log("Fetching branch: " + branch_edit.text)
    api.api_get("/branches/" + branch_edit.text, "refresh_branch_info")
    
    var timer = get_tree().create_timer(5.0)
    timer.timeout.connect(func():
        if progress_bar.value == 10:
            _log("[color=red]抓取超时！可能原因：1. 网络断开 2. 仓库/分支名错 3. Token失效[/color]")
            _set_progress(0, "Timeout")
    )

# ============ 回调中心 ============
func _on_api_resp(tag: String, code: int, text: String, index: int):
    match tag:
        "refresh_branch_info":
            if code != 200:
                _log("[color=red]HTTP " + str(code) + ": " + text + "[/color]")
                _set_progress(0, "Failed")
                return
            var json = JSON.parse_string(text)
            if json and json.has("commit"):
                head_tree_sha = json["commit"]["commit"]["tree"]["sha"]
                _log("Branch found. Fetching tree...")
                api.api_get("/git/trees/" + head_tree_sha + "?recursive=1", "refresh_tree")
            else:
                _log("[color=red]Parse error: " + text + "[/color]")
                _set_progress(0, "Parse Error")
                
        "refresh_tree":
            var json = JSON.parse_string(text)
            if json and json.has("tree"):
                remote_state.clear()
                for item in json["tree"]:
                    if item["type"] == "blob":
                        remote_state[item["path"]] = item["sha"]
                _refresh_file_list()
                _log("Remote updated, %d files" % remote_state.size())
                _set_progress(100, "Refresh done")
            else:
                _log("[color=red]Refresh failed: " + text + "[/color]")
                _set_progress(0, "Failed")
                
        "pull_file":
            var json = JSON.parse_string(text)
            if json and json.has("content"):
                var data = Marshalls.base64_to_raw(json["content"].replace("\n", ""))
                var f = FileAccess.open("res://" + temp_path, FileAccess.WRITE)
                f.store_buffer(data)
                f.close()
                _log("[color=green]Pulled: " + temp_path + "[/color]")
                EditorInterface.get_resource_filesystem().scan()
                _refresh_file_list()
                _set_progress(100, "Pull done")
            else:
                _log("[color=red]Pull failed[/color]")

        "diff":
            if code != 200:
                diff_left.text = "Remote file not found"
                return
            var json = JSON.parse_string(text)
            if json == null or not json.has("content"):
                diff_left.text = "Parse error"
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
            _set_progress(100, "Diff done")

        "history":
            var json = JSON.parse_string(text)
            if json is Array:
                commit_history_data = json
                graph_control.custom_minimum_size.y = max(500, json.size() * 40 + 40)
                graph_control.queue_redraw()
                _log("History fetched, graph rendered")
                _set_progress(100, "History done")

        "commit_details":
            var json = JSON.parse_string(text)
            if json and json.has("files"):
                var txt = "[b]修改的文件:[/b]\n\n"
                for f in json["files"]:
                    txt += "[color=cyan]" + f["status"] + "[/color] " + f["filename"] + "\n"
                history_files_label.text = txt

        "create_pr":
            var json = JSON.parse_string(text)
            if json and json.has("html_url"):
                _log("[color=green]PR created: " + json["html_url"] + "[/color]")
            elif code == 422:
                _log("[color=red]PR 创建失败：远程仓库找不到分支 '" + branch_edit.text + "'。请先点击 '同步' 传上去。[/color]")

        "fetch_issues":
            var json = JSON.parse_string(text)
            if json is Array:
                var txt = "[b]当前未关闭的 Issues:[/b]\n\n"
                if json.is_empty():
                    txt += "太棒了，没有 Issue！\n"
                else:
                    for issue in json:
                        txt += "[color=yellow]#" + str(issue["number"]) + "[/color] " + issue["title"] + "\n"
                history_files_label.text = txt

        "trigger_action":
            if code == 204:
                _log("[color=green]云编译已触发！去 GitHub 网页看进度吧。[/color]")
            else:
                _log("[color=red]触发失败: " + text + "[/color]")

        "release":
            var json = JSON.parse_string(text)
            if json and json.has("id"):
                release_id = json["id"]
                _log("Release created ID: " + str(release_id))
                _upload_apk(pending_apk_path)

        "upload_apk":
            if code == 201:
                _log("[color=green]APK Upload Success![/color]")
            else:
                _log("[color=red]APK Upload Failed: " + str(code) + "[/color]")

func _create_pull_request():
    _setup_api()
    if branch_edit.text == "main":
        _log("[color=orange]请先切换到非 main 分支再发起 PR[/color]")
        return
    var body = JSON.stringify({
        "title": "Merge " + branch_edit.text + " into main",
        "head": branch_edit.text,
        "base": "main",
        "body": "Created from Godot API Client"
    })
    _set_progress(20, "Creating PR...")
    api.api_post("/pulls", body, "create_pr")

func _show_issues():
    _setup_api()
    history_window.show()
    history_files_label.text = "加载 Issues 中..."
    api.api_get("/issues?state=open", "fetch_issues")

func _trigger_action():
    _setup_api()
    if branch_edit.text.strip_edges() == "": branch_edit.text = "main"
    var body = JSON.stringify({"ref": branch_edit.text})
    _set_progress(30, "Triggering Action...")
    api.api_post("/actions/workflows/main.yml/dispatches", body, "trigger_action")

func _show_commit_history():
    _setup_api()
    history_window.show()
    selected_commit_idx = -1
    history_files_label.text = "点击左侧节点查看文件差异"
    _set_progress(30, "Fetching history...")
    api.api_get("/commits?per_page=15", "history")

func _fetch_commit_files(sha: String):
    history_files_label.text = "加载中..."
    api.api_get("/commits/" + sha, "commit_details")

func _pull_selected():
    _setup_api()
    var item = file_tree.get_selected()
    if item == null: return
    var info = item.get_metadata(0)
    if info.is_empty(): return
    temp_path = info["path"]
    if branch_edit.text.strip_edges() == "": branch_edit.text = "main"
    _set_progress(30, "Pulling: " + temp_path)
    api.api_get("/contents/%s?ref=%s" % [temp_path, branch_edit.text], "pull_file")

func _show_local_diff():
    _setup_api()
    var item = file_tree.get_selected()
    if item == null: 
        _log("[color=red]Select a file first[/color]")
        return
    var info = item.get_metadata(0)
    if info.is_empty(): return
    temp_path = info["path"]
    diff_window.show()
    diff_left.text = "Loading remote..."
    diff_right.text = "Loading local..."
    if branch_edit.text.strip_edges() == "": branch_edit.text = "main"
    api.api_get("/contents/%s?ref=%s" % [temp_path, branch_edit.text], "diff")

func _publish_release():
    _setup_api()
    var fd = FileDialog.new()
    fd.access = FileDialog.ACCESS_FILESYSTEM
    fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    add_child(fd)
    fd.file_selected.connect(func(path):
        _log("Creating Release...")
        pending_apk_path = path
        var body = JSON.stringify({
            "tag_name": "v" + Time.get_datetime_string_from_system().replace(":","-"),
            "name": "Godot Build",
            "body": "Auto release from Godot"
        })
        _set_progress(20, "Creating Release...")
        api.api_post("/releases", body, "release")
        fd.queue_free()
    )
    fd.canceled.connect(func(): fd.queue_free())
    fd.popup_centered_ratio(0.7)

func _upload_apk(path):
    _log("Uploading APK: " + path)
    var f = FileAccess.open(path, FileAccess.READ)
    var bytes = f.get_buffer(f.get_length())
    f.close()
    var url = "https://uploads.github.com/repos/%s/%s/releases/%d/assets?name=%s" % [
        owner_edit.text, repo_edit.text, release_id, path.get_file()
    ]
    api.upload_apk(url, bytes, "upload_apk")

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

func _load_state():
    if FileAccess.file_exists(STATE_PATH):
        var s = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
        if s is Dictionary: local_state = s

func _save_state():
    var f = FileAccess.open(STATE_PATH, FileAccess.WRITE)
    f.store_string(JSON.stringify(local_state))
    f.close()

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
    _log("[color=cyan]Snapshot created: " + bp + "[/color]")

# ============ 提交图 UI ============
func _create_history_window():
    history_window = Window.new()
    history_window.title = "Commit Graph"
    history_window.size = Vector2i(900, 600)
    history_window.visible = false
    history_window.transient = true
    var split = HSplitContainer.new()
    split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    split.offset_bottom = -40
    history_window.add_child(split)
    var scroll = ScrollContainer.new()
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    split.add_child(scroll)
    graph_control = Control.new()
    graph_control.custom_minimum_size = Vector2(400, 500)
    graph_control.draw.connect(_draw_graph)
    graph_control.gui_input.connect(_gui_input_graph)
    scroll.add_child(graph_control)
    history_files_label = RichTextLabel.new()
    history_files_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    history_files_label.bbcode_enabled = true
    history_files_label.text = "点击左侧节点查看文件差异"
    split.add_child(history_files_label)
    var close = Button.new()
    close.text = "Close"
    close.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
    close.offset_top = -35
    close.pressed.connect(func(): history_window.hide())
    history_window.add_child(close)
    add_child(history_window)

func _draw_graph():
    if commit_history_data.is_empty(): return
    var font = ThemeDB.fallback_font
    var y = 30
    var node_x = 40
    var text_x = 80
    for i in range(commit_history_data.size()):
        var c = commit_history_data[i]
        var sha = c["sha"].substr(0, 7)
        var msg = c["commit"]["message"].strip_edges()
        if i > 0:
            graph_control.draw_line(Vector2(node_x, y - 40), Vector2(node_x, y), Color(0.3, 0.6, 1), 2.0)
        var color = Color(1, 0.8, 0.3) if i == selected_commit_idx else Color(0.4, 0.8, 1)
        graph_control.draw_circle(Vector2(node_x, y), 6.0, color)
        graph_control.draw_string(font, Vector2(text_x, y + 5), "[" + sha + "] " + msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.9, 0.9, 0.9))
        y += 40

func _gui_input_graph(event):
    if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
        var idx = int((event.position.y - 10) / 40)
        if idx >= 0 and idx < commit_history_data.size():
            selected_commit_idx = idx
            graph_control.queue_redraw()
            _fetch_commit_files(commit_history_data[idx]["sha"])

func _create_diff_window():
    diff_window = Window.new()
    diff_window.title = "Local Diff"
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
    ll.text = "Remote"
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
    rl.text = "Local"
    rl.add_theme_color_override("font_color", Color(0.3,0.8,0.3))
    rb.add_child(rl)
    diff_right = RichTextLabel.new()
    diff_right.size_flags_vertical = Control.SIZE_EXPAND_FILL
    diff_right.bbcode_enabled = true
    rb.add_child(diff_right)
    split.add_child(rb)
    var close = Button.new()
    close.text = "Close"
    close.pressed.connect(func(): diff_window.hide())
    vbox.add_child(close)
    add_child(diff_window)
