use std::mem::size_of;
use windows::Win32::{
    Foundation::FILETIME,
    System::{
        Performance::{QueryPerformanceCounter, QueryPerformanceFrequency},
        ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS_EX},
        Threading::{GetCurrentProcess, GetProcessTimes},
    },
};

// QPC has one monotonic timebase across processes on the same machine.
pub(super) fn clock_us() -> u64 {
    static FREQUENCY: std::sync::OnceLock<i64> = std::sync::OnceLock::new();
    let frequency = FREQUENCY.get_or_init(|| {
        let mut hz = 0;
        unsafe { QueryPerformanceFrequency(&mut hz) }.expect("Windows QPC frequency");
        hz
    });
    let mut ticks = 0;
    unsafe { QueryPerformanceCounter(&mut ticks) }.expect("Windows QPC counter");
    (ticks as u128 * 1_000_000 / *frequency as u128) as u64
}

pub(super) fn private_bytes() -> Option<usize> {
    process_private(unsafe { GetCurrentProcess() })
}

pub(super) fn process_private(process: windows::Win32::Foundation::HANDLE) -> Option<usize> {
    let mut counters = PROCESS_MEMORY_COUNTERS_EX::default();
    let size = size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32;
    unsafe {
        GetProcessMemoryInfo(
            process,
            (&mut counters as *mut PROCESS_MEMORY_COUNTERS_EX).cast(),
            size,
        )
    }
    .ok()?;
    Some(counters.PrivateUsage)
}

pub(super) fn sample_pair(child: &std::process::Child, peak: &mut Option<usize>) {
    use std::os::windows::io::AsRawHandle;
    let child = windows::Win32::Foundation::HANDLE(child.as_raw_handle());
    if let (Some(a), Some(b)) = (private_bytes(), process_private(child)) {
        *peak = Some(peak.unwrap_or_default().max(a + b));
    }
}

pub(super) fn cpu_us() -> Option<u64> {
    let [mut created, mut exit, mut kernel, mut user] = [FILETIME::default(); 4];
    unsafe {
        GetProcessTimes(
            GetCurrentProcess(),
            &mut created,
            &mut exit,
            &mut kernel,
            &mut user,
        )
    }
    .ok()?;
    let ticks = |t: FILETIME| (u64::from(t.dwHighDateTime) << 32) | u64::from(t.dwLowDateTime);
    Some((ticks(kernel) + ticks(user)) / 10)
}
