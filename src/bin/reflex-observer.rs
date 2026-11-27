#[cfg(windows)]
#[path = "../dev_context.rs"]
mod dev_context;
#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.as_slice() == ["protocol"] {
        println!("reflex.observer.2");
        return Ok(());
    }
    dev_context::run(&args)
}
#[cfg(not(windows))]
fn main() { std::process::exit(2) }
