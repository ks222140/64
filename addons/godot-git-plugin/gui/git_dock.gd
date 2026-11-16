@tool
extends VBoxContainer

const CONFIG_PATH = "user://godot_git_config.cfg"

var token_edit: LineEdit
var owner_edit: LineEdit
var repo_edit: LineEdit
var branch_edit: LineEdit
var path_edit: LineEdit
var log_label: RichTextLabel
var http: HTTPRequest

# 独立的一个 HTTP 请求，专供弹窗使用
var popup_http: HTTPRequest
var diff_window: Window
var diff_text: RichTextLabel

enum RequestType { NONE, PULL, GET_SHA_FOR_PUSH, PUSH, GET_COMMITS, GET_DIFF, GET_SHA_BATCH, PUSH_BATCH }
var current_request = RequestType.NONE
var temp_file_content = ""
var temp_sha = ""
var upload_queue: Array = []
var is_batch_uploading = false

func _ready():
    http = HTTPRequest.new()
    add_child(http)
    http.request_completed.connect(_on_request_completed)

    popup_http = HTTPRequest.new()
    add_child(popup_http)
    popup_http.request_completed.connect(_on_popup_diff_completed)

    # --- 构建 UI ---
    var title = Label.new()
    title.text = "GitHub 同步工具"
    add_child(title)

    token_edit = LineEdit.new()
    token_edit.placeholder_text = "Token (PAT)"
    token_edit.secret = true
    add_child(token_edit)

    var hbox1 = HBoxContainer.new()
    owner_edit = LineEdit.new()
    owner_edit.placeholder_text = "用户名"
    owner_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hbox1.add_child(owner_edit)
    repo_edit = LineEdit.new()
    repo_edit.placeholder_text = "仓库名"
    repo_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hbox1.add_child(repo_edit)
    add_child(hbox1)

    branch_edit = LineEdit.new()
    branch_edit.placeholder_text = "分支 (如 main)"
    branch_edit.text = "main"
    add_child(branch_edit)

    var hbox2 = HBoxContainer.new()
    path_edit = LineEdit.new()
    path_edit.placeholder_text = "远程/本地路径"
    path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hbox2.add_child(path_edit)
    var browse_btn = Button.new()
    browse_btn.text = "选择文件..."
    browse_btn.pressed.connect(_on_browse_pressed)
    hbox2.add_child(browse_btn)
    add_child(hbox2)

    var save_btn = Button.new()
    save_btn.text = "保存配置"
    save_btn.pressed.connect(_save_config)
    add_child(save_btn)

    var pull_btn = Button.new()
    pull_btn.text = "拉取此文件"
    pull_btn.pressed.connect(_pull_file)
    add_child(pull_btn)

    var push_btn = Button.new()
    push_btn.text = "上传此文件"
    push_btn.pressed.connect(_push_file)
    add_child(push_btn)

    var push_all_btn = Button.new()
    push_all_btn.text = "上传整个项目"
    push_all_btn.pressed.connect(_push_entire_project)
    add_child(push_all_btn)

    var diff_btn = Button.new()
    diff_btn.text = "弹窗查看最新 Diff"
    diff_btn.pressed.connect(_fetch_latest_diff)
    add_child(diff_btn)

    log_label = RichTextLabel.new()
    log_label.custom_minimum_size = Vector2(0, 200)
    log_label.scroll_following = true
    log_label.bbcode_enabled = true
    add_child(log_label)

    _create_diff_window()
    _load_config()

# --- 创建 Diff 弹窗 ---
func _create_diff_window():
    diff_window = Window.new()
    diff_window.title = "Git Diff 查看器"
    diff_window.size = Vector2i(800, 600)
    diff_window.visible = false
    # 弹出为独立窗口而不是内嵌
    diff_window.transient = true 
    
    var vbox = VBoxContainer.new()
    vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    diff_window.add_child(vbox)
    
    diff_text = RichTextLabel.new()
    diff_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
    diff_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    diff_text.bbcode_enabled = true
    diff_text.selection_enabled = true
    vbox.add_child(diff_text)
    
    var close_btn = Button.new()
    close_btn.text = "关闭"
    close_btn.pressed.connect(func(): diff_window.hide())
    vbox.add_child(close_btn)
    
    add_child(diff_window)

# --- 解决只能选脚本的问题：调用原生原生文件对话框 ---
func _on_browse_pressed():
    var file_dialog = FileDialog.new()
    file_dialog.access = FileDialog.ACCESS_RESOURCES
    file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    # 去掉限制，允许选择任何文件！
    file_dialog.filters = PackedStringArray(["*"])
    add_child(file_dialog)
    
    file_dialog.file_selected.connect(func(path):
        var relative_path = path.replace("res://", "")
        path_edit.text = relative_path
        file_dialog.queue_free()
    )
    file_dialog.canceled.connect(func(): file_dialog.queue_free())
    
    file_dialog.popup_centered_ratio(0.6)


# --- 核心逻辑（保留你之前好用的部分） ---
func _log(msg): log_label.append_text(msg + "\n")

func _save_config():
    var cfg = ConfigFile.new()
    cfg.set_value("github", "token", token_edit.text)
    cfg.set_value("github", "owner", owner_edit.text)
    cfg.set_value("github", "repo", repo_edit.text)
    cfg.set_value("github", "branch", branch_edit.text)
    cfg.save(CONFIG_PATH)
    _log("配置已保存")

func _load_config():
    var cfg = ConfigFile.new()
    if cfg.load(CONFIG_PATH) != OK: return
    token_edit.text = cfg.get_value("github", "token", "")
    owner_edit.text = cfg.get_value("github", "owner", "")
    repo_edit.text = cfg.get_value("github", "repo", "")
    branch_edit.text = cfg.get_value("github", "branch", "main")

func _api_url(path: String) -> String:
    return "https://api.github.com/repos/%s/%s/contents/%s?ref=%s" % [
        owner_edit.text, repo_edit.text, path, branch_edit.text
    ]

func _headers() -> PackedStringArray:
    return PackedStringArray([
        "Authorization: Bearer " + token_edit.text,
        "Accept: application/vnd.github+json",
        "User-Agent: Godot-Git-Uploader"
    ])

func _pull_file():
    if path_edit.text.is_empty(): return
    _log("正在拉取: " + path_edit.text)
    current_request = RequestType.PULL
    http.request(_api_url(path_edit.text), _headers(), HTTPClient.METHOD_GET)

func _push_file():
    if path_edit.text.is_empty(): return
    var local_path = "res://" + path_edit.text
    if not FileAccess.file_exists(local_path):
        _log("[color=red]本地文件不存在: " + local_path + "[/color]")
        return
    
    var file = FileAccess.open(local_path, FileAccess.READ)
    temp_file_content = Marshalls.raw_to_base64(file.get_buffer(file.get_length()))
    file.close()
    
    _log("正在获取远程 SHA: " + path_edit.text)
    current_request = RequestType.GET_SHA_FOR_PUSH
    http.request(_api_url(path_edit.text), _headers(), HTTPClient.METHOD_GET)

func _push_entire_project():
    if is_batch_uploading: return
    is_batch_uploading = true
    upload_queue.clear()
    _log("[color=cyan]开始扫描项目文件...[/color]")
    _scan_dir("res://")
    
    if upload_queue.size() == 0:
        is_batch_uploading = false
        return
    _log("共找到 %d 个文件，开始上传..." % upload_queue.size())
    _process_next_upload()

func _scan_dir(path: String):
    var dir = DirAccess.open(path)
    if not dir: return
    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if file_name.begins_with("."):
            file_name = dir.get_next()
            continue
        var full_path = path.path_join(file_name)
        if dir.current_is_dir():
            _scan_dir(full_path)
        else:
            if file_name.get_extension() in ["gd", "tscn", "tres", "cfg", "godot", "txt", "json", "md"]:
                upload_queue.append(full_path)
        file_name = dir.get_next()
    dir.list_dir_end()

func _process_next_upload():
    if upload_queue.size() == 0:
        _log("[color=green]=== 所有文件上传完成！ ===[/color]")
        is_batch_uploading = false
        return
    var next_file = upload_queue.pop_front()
    var relative_path = next_file.replace("res://", "")
    var file = FileAccess.open(next_file, FileAccess.READ)
    temp_file_content = Marshalls.raw_to_base64(file.get_buffer(file.get_length()))
    file.close()
    current_request = RequestType.GET_SHA_BATCH
    path_edit.text = relative_path
    http.request(_api_url(relative_path), _headers(), HTTPClient.METHOD_GET)

func _fetch_latest_diff():
    diff_window.show()
    diff_text.text = "正在获取数据..."
    var url = "https://api.github.com/repos/%s/%s/commits?per_page=2" % [owner_edit.text, repo_edit.text]
    if not path_edit.text.is_empty():
        url += "&path=" + path_edit.text
    # 交给独立的 popup_http 去处理
    popup_http.request(url, _headers(), HTTPClient.METHOD_GET)

func _on_request_completed(result, response_code, headers, body):
    if result != HTTPRequest.RESULT_SUCCESS:
        if is_batch_uploading: _process_next_upload()
        return
    var text = body.get_string_from_utf8()
    var req = current_request
    current_request = RequestType.NONE

    if response_code != 200 and response_code != 201:
        if (req == RequestType.GET_SHA_FOR_PUSH or req == RequestType.GET_SHA_BATCH) and response_code == 404:
            pass
        else:
            _log("[color=red]HTTP " + str(response_code) + ": " + text + "[/color]")
            if is_batch_uploading: _process_next_upload()
            return
    
    var json = JSON.parse_string(text)
    if json == null and response_code != 404: 
        if is_batch_uploading: _process_next_upload()
        return

    match req:
        RequestType.PULL:
            if json and json.has("content"):
                var data = Marshalls.base64_to_raw(json["content"].replace("\n", ""))
                var f = FileAccess.open("res://" + path_edit.text, FileAccess.WRITE)
                f.store_buffer(data)
                f.close()
                _log("[color=green]拉取成功: " + path_edit.text + "[/color]")
                EditorInterface.get_resource_filesystem().scan()

        RequestType.GET_SHA_FOR_PUSH, RequestType.GET_SHA_BATCH:
            temp_sha = json["sha"] if response_code == 200 and json and json.has("sha") else ""
            if req == RequestType.GET_SHA_FOR_PUSH: current_request = RequestType.PUSH
            else: current_request = RequestType.PUSH_BATCH
            var payload = { "message": "Update " + path_edit.text, "content": temp_file_content, "branch": branch_edit.text }
            if not temp_sha.is_empty(): payload["sha"] = temp_sha
            http.request(_api_url(path_edit.text), _headers(), HTTPClient.METHOD_PUT, JSON.stringify(payload))

        RequestType.PUSH, RequestType.PUSH_BATCH:
            _log("[color=green]成功: " + path_edit.text + "[/color]")
            if req == RequestType.PUSH_BATCH:
                await get_tree().create_timer(1.0).timeout
                _process_next_upload()

# --- 独立的 Diff 弹窗回调 ---
func _on_popup_diff_completed(result, response_code, headers, body):
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        diff_text.text = "获取提交历史失败"
        return
        
    var json = JSON.parse_string(body.get_string_from_utf8())
    if json is Array and json.size() >= 2:
        var url = "https://api.github.com/repos/%s/%s/compare/%s...%s" % [
            owner_edit.text, repo_edit.text, json[1]["sha"], json[0]["sha"]
        ]
        # 请求对比数据
        var second_http = HTTPRequest.new()
        add_child(second_http)
        second_http.request_completed.connect(_on_popup_compare_completed)
        second_http.request(url, _headers(), HTTPClient.METHOD_GET)
    else:
        diff_text.text = "提交历史不足 2 次，无法比较"

func _on_popup_compare_completed(result, response_code, headers, body):
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        diff_text.text = "获取 Diff 失败"
        return
    
    var json = JSON.parse_string(body.get_string_from_utf8())
    var bb_text = ""
    if json and json.has("files"):
        for file_data in json["files"]:
            bb_text += "[b][color=yellow]" + file_data["filename"] + "[/color][/b]\n"
            if file_data.has("patch"):
                var patch = file_data["patch"]
                patch = patch.replace("\n+", "\n[color=green]+").replace("\n-", "\n[color=red]-")
                # 顺手高亮一下 @@ 标记
                patch = patch.replace("@@", "[color=cyan]@@").replace("@@", "@@[/color]")
                bb_text += patch + "[/color]\n\n"
            else:
                bb_text += "（二进制文件或无文本变更）\n\n"
    else:
        bb_text = "没有文件变更。"
        
    diff_text.text = bb_text
