{
  "targets": [
    {
      "target_name": "nexaloid_node",
      "sources": ["src/nexaloid_node.c"],
      "include_dirs": ["../../core/include"],
      "conditions": [
        ["OS==\"win\"", {
          "libraries": [
            "<(module_root_dir)/../../core/zig-out/lib/nexaloid.lib",
            "ucrt.lib"
          ]
        }],
        ["OS==\"linux\"", {
          "libraries": ["-L<(module_root_dir)/../../core/zig-out/lib", "-lnexaloid"]
        }],
        ["OS==\"mac\"", {
          "libraries": ["-L<(module_root_dir)/../../core/zig-out/lib", "-lnexaloid"]
        }]
      ]
    }
  ]
}
