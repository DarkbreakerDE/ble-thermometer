pub mod api;
mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */

/// Resolve the actual Native Assets bundle path for FRB's dynamic loader.
/// No BLE, device identity or user data crosses this bootstrap function.
#[cfg(unix)]
#[no_mangle]
pub extern "C" fn thermometer_asset_path() -> *const std::ffi::c_char {
    use std::{ffi::CString, sync::OnceLock};
    static PATH: OnceLock<Option<CString>> = OnceLock::new();
    PATH.get_or_init(|| unsafe {
        let mut info: libc::Dl_info = std::mem::zeroed();
        if libc::dladdr(
            thermometer_asset_path as *const () as *const libc::c_void,
            &mut info,
        ) == 0
            || info.dli_fname.is_null()
        {
            None
        } else {
            Some(std::ffi::CStr::from_ptr(info.dli_fname).to_owned())
        }
    })
    .as_ref()
    .map_or(std::ptr::null(), |path| path.as_ptr())
}
