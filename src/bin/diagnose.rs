fn main() {
    println!("Catengar {} · Rust / NSH", catengar::VERSION);
    match catengar::auth::discover() {
        catengar::auth::Identity::Ready(c) => println!(
            "客户端 PID {}，端口 {}，认证已就绪（凭据不输出）",
            c.pid, c.port
        ),
        catengar::auth::Identity::AdminRequired => {
            println!("客户端需要管理员权限才能读取认证。诊断工具不会自动请求授权。")
        }
        catengar::auth::Identity::Failed => {
            println!("认证读取失败；请检查权限，或在客户端就绪后重新运行诊断。")
        }
        state => println!("{}", state.label()),
    }
    println!("数据目录：{}", catengar::storage::data_dir().display());
}
