fn main() {
    println!("cargo:rerun-if-changed=assets/catengar.ico");
    println!("cargo:rerun-if-changed=assets/catengar.manifest");
    winresource::WindowsResource::new()
        .set_icon("assets/catengar.ico")
        .set_manifest_file("assets/catengar.manifest")
        .set("ProductName", "Catengar")
        .set("FileDescription", "Catengar League 助手")
        .compile()
        .expect("Windows resources");
}
