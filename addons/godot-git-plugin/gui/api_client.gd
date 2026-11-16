@tool
extends Node
class_name GodotGitApi

signal response_received(tag, code, text, index)

var token = ""
var _owner = ""
var repo = ""

func setup(t, o, r):
    token = t
    _owner = o
    repo = r

func _headers() -> PackedStringArray:
    return PackedStringArray([
        "Authorization: Bearer " + token,
        "Accept: application/vnd.github+json",
        "User-Agent: Godot-Git-Client"
    ])

func _url(path: String) -> String:
    return "https://api.github.com/repos/%s/%s%s" % [_owner, repo, path]

func api_get(path: String, tag: String, index: int = -1):
    var req = HTTPRequest.new()
    add_child(req)
    req.request_completed.connect(func(r, c, h, b): 
        var text = b.get_string_from_utf8()
        response_received.emit(tag, c, text, index)
        req.queue_free()
    )
    var full_url = path if path.begins_with("http") else _url(path)
    req.request(full_url, _headers(), HTTPClient.METHOD_GET)

func api_post(path: String, body: String, tag: String, index: int = -1):
    var req = HTTPRequest.new()
    add_child(req)
    req.request_completed.connect(func(r, c, h, b): 
        var text = b.get_string_from_utf8()
        response_received.emit(tag, c, text, index)
        req.queue_free()
    )
    var full_url = path if path.begins_with("http") else _url(path)
    req.request(full_url, _headers(), HTTPClient.METHOD_POST, body)

func api_patch(path: String, body: String, tag: String):
    var req = HTTPRequest.new()
    add_child(req)
    req.request_completed.connect(func(r, c, h, b): 
        var text = b.get_string_from_utf8()
        response_received.emit(tag, c, text, -1)
        req.queue_free()
    )
    req.request(_url(path), _headers(), HTTPClient.METHOD_PATCH, body)

func upload_apk(url: String, bytes: PackedByteArray, tag: String):
    var req = HTTPRequest.new()
    add_child(req)
    req.request_completed.connect(func(r, c, h, b): 
        var text = b.get_string_from_utf8()
        response_received.emit(tag, c, text, -1)
        req.queue_free()
    )
    var h = PackedStringArray([
        "Authorization: Bearer " + token,
        "Content-Type: application/octet-stream",
        "User-Agent: Godot-Git-Client"
    ])
    req.request_raw(url, h, HTTPClient.METHOD_POST, bytes)
