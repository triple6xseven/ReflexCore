#[cfg(windows)]
#[path = "../dev_context.rs"]
mod dev_context;
#[cfg(windows)]
#[path = "../hook_arrival.rs"]
mod hook_arrival;
#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.as_slice() == ["protocol"] {
        println!("reflex.observer.2");
        return Ok(());
    }
    if args.as_slice() == ["guard-protocol"] {
        println!("reflex.guard.1");
        return Ok(());
    }
    if args.as_slice() == ["hook-protocol"] {
        println!("reflex.hook.1");
        return Ok(());
    }
    if let [mode, root] = args.as_slice() {
        if mode == "capture" || mode == "diagnose" {
            if hook_arrival::capture(std::path::Path::new(root), mode == "diagnose").is_err() {
                std::process::exit(1)
            }
            return Ok(());
        }
    }
    dev_context::run(&args)
}
#[cfg(not(windows))]
fn main() {
    std::process::exit(2)
}
