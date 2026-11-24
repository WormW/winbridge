use std::net::{IpAddr, Ipv4Addr};

pub const HOST_VERSION: &str = "0.5.4";

pub const CAP_PROCESS_AUDIO: u32 = 1 << 0;
pub const CAP_FILE_PULL: u32 = 1 << 1;
pub const CAP_CLIPBOARD_FILES: u32 = 1 << 2;
pub const CAP_ADAPTIVE_VIDEO: u32 = 1 << 3;
pub const CAP_PER_WINDOW_MUTE: u32 = 1 << 4;
pub const CAP_WOL_MAC: u32 = 1 << 5;
pub const CAP_QUIC: u32 = 1 << 6;
pub const CAP_NOTIFICATIONS: u32 = 1 << 7;

pub const HOST_CAPABILITIES: u32 = CAP_PROCESS_AUDIO
    | CAP_FILE_PULL
    | CAP_CLIPBOARD_FILES
    | CAP_ADAPTIVE_VIDEO
    | CAP_PER_WINDOW_MUTE
    | CAP_WOL_MAC
    | CAP_QUIC
    | CAP_NOTIFICATIONS;

const IF_TYPE_ETHERNET_CSMACD: u32 = 6;
const IF_TYPE_SOFTWARE_LOOPBACK: u32 = 24;
const IF_TYPE_IEEE80211: u32 = 71;
const IF_TYPE_TUNNEL: u32 = 131;

#[derive(Clone, Debug, PartialEq, Eq)]
struct AdapterCandidate {
    ipv4s: Vec<Ipv4Addr>,
    mac: String,
    if_type: u32,
    oper_up: bool,
}

pub fn format_mac(bytes: &[u8]) -> Option<String> {
    if bytes.len() != 6 {
        return None;
    }
    if bytes.iter().all(|&b| b == 0) || bytes.iter().all(|&b| b == 0xFF) {
        return None;
    }
    Some(format!(
        "{:02X}:{:02X}:{:02X}:{:02X}:{:02X}:{:02X}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]
    ))
}

fn ipv4_priority(ip: Ipv4Addr) -> u8 {
    if ip.is_loopback() || ip.is_unspecified() {
        return 0;
    }
    if ip.is_link_local() {
        return 1;
    }
    if ip.is_private() {
        return 3;
    }
    2
}

fn select_best_adapter(
    candidates: &[AdapterCandidate],
    preferred_ip: Option<Ipv4Addr>,
) -> (Option<Ipv4Addr>, Option<String>) {
    if let Some(pref) = preferred_ip.filter(|ip| !ip.is_unspecified() && !ip.is_loopback()) {
        if let Some(matched) = candidates.iter().find(|c| c.ipv4s.contains(&pref)) {
            return (Some(pref), Some(matched.mac.clone()));
        }
    }

    let mut best: Option<(u32, Option<Ipv4Addr>, String)> = None;
    for cand in candidates {
        if !cand.oper_up
            || cand.if_type == IF_TYPE_SOFTWARE_LOOPBACK
            || cand.if_type == IF_TYPE_TUNNEL
        {
            continue;
        }
        let best_ip = cand
            .ipv4s
            .iter()
            .copied()
            .filter(|ip| !ip.is_loopback() && !ip.is_unspecified())
            .max_by_key(|&ip| ipv4_priority(ip));
        let ip_score = best_ip.map_or(0, |ip| u32::from(ipv4_priority(ip)) * 100);
        let type_score = match cand.if_type {
            IF_TYPE_ETHERNET_CSMACD => 30,
            IF_TYPE_IEEE80211 => 20,
            _ => 10,
        };
        let score = ip_score + type_score;
        if best.as_ref().is_none_or(|(prev, _, _)| score > *prev) {
            best = Some((score, best_ip, cand.mac.clone()));
        }
    }

    match best {
        Some((_, ip, mac)) => (ip.or(preferred_ip), Some(mac)),
        None => (preferred_ip, None),
    }
}

#[cfg(windows)]
fn enumerate_adapters() -> Vec<AdapterCandidate> {
    use std::{ffi::c_void, mem, ptr};
    use windows_sys::Win32::{
        Foundation::{ERROR_BUFFER_OVERFLOW, ERROR_SUCCESS},
        NetworkManagement::IpHelper::{
            GetAdaptersAddresses, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER,
            GAA_FLAG_SKIP_MULTICAST, IP_ADAPTER_ADDRESSES_LH,
        },
        Networking::WinSock::{AF_INET, SOCKADDR_IN},
    };

    let flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    let mut size: u32 = 16 * 1024;
    let mut buf: Vec<u8> = Vec::new();
    let mut ok = false;

    for _ in 0..3 {
        buf.resize(size as usize, 0);
        let status = unsafe {
            GetAdaptersAddresses(
                u32::from(AF_INET),
                flags,
                ptr::null_mut::<c_void>() as _,
                buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH,
                &mut size,
            )
        };
        if status == ERROR_SUCCESS {
            ok = true;
            break;
        }
        if status != ERROR_BUFFER_OVERFLOW || size == 0 || size > 4 * 1024 * 1024 {
            break;
        }
    }

    if !ok || buf.is_empty() {
        return Vec::new();
    }

    let mut out = Vec::new();
    let mut cur = buf.as_ptr() as *const IP_ADAPTER_ADDRESSES_LH;
    while !cur.is_null() {
        let adapter = unsafe { &*cur };
        let mac_len = (adapter.PhysicalAddressLength as usize).min(adapter.PhysicalAddress.len());
        if let Some(mac) = format_mac(&adapter.PhysicalAddress[..mac_len]) {
            let mut ipv4s = Vec::new();
            let mut uni = adapter.FirstUnicastAddress;
            while !uni.is_null() {
                let u = unsafe { &*uni };
                let sa = u.Address.lpSockaddr;
                if !sa.is_null()
                    && (u.Address.iSockaddrLength as usize) >= mem::size_of::<SOCKADDR_IN>()
                {
                    let family = unsafe { (*sa).sa_family };
                    if family == AF_INET {
                        let sin = sa as *const SOCKADDR_IN;
                        let s_addr = unsafe { (*sin).sin_addr.S_un.S_addr };
                        ipv4s.push(Ipv4Addr::from(s_addr.to_ne_bytes()));
                    }
                }
                uni = u.Next;
            }
            out.push(AdapterCandidate {
                ipv4s,
                mac,
                if_type: adapter.IfType,
                // IfOperStatusUp == 1
                oper_up: adapter.OperStatus == 1,
            });
        }
        cur = adapter.Next;
    }
    out
}

#[cfg(not(windows))]
fn enumerate_adapters() -> Vec<AdapterCandidate> {
    Vec::new()
}

pub fn detect_lan_ipv4_and_mac(preferred: Option<IpAddr>) -> (Option<Ipv4Addr>, Option<String>) {
    let preferred_v4 = preferred.and_then(|ip| match ip {
        IpAddr::V4(v4) => Some(v4),
        IpAddr::V6(v6) => v6.to_ipv4_mapped(),
    });
    let candidates = enumerate_adapters();
    select_best_adapter(&candidates, preferred_v4)
}

pub fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        let unreserved = byte.is_ascii_alphanumeric()
            || matches!(byte, b'-' | b'_' | b'.' | b'~');
        if unreserved {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

pub fn build_pairing_uri(
    host: &str,
    port: u16,
    token: &str,
    fingerprint: Option<&str>,
    mac: Option<&str>,
    host_name: Option<&str>,
    use_tls: bool,
) -> String {
    let host_part = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.to_owned()
    };
    let mut params = Vec::new();
    if let Some(name) = host_name.filter(|s| !s.trim().is_empty()) {
        params.push(format!("name={}", percent_encode(name.trim())));
    }
    if !token.is_empty() {
        params.push(format!("token={}", percent_encode(token)));
    }
    if let Some(fp) = fingerprint.filter(|s| !s.trim().is_empty()) {
        params.push(format!("fp={}", percent_encode(fp.trim())));
    }
    if let Some(mac) = mac.filter(|s| !s.trim().is_empty()) {
        params.push(format!("mac={}", percent_encode(mac.trim())));
    }
    params.push(format!("tls={}", if use_tls { "1" } else { "0" }));
    format!("winbridge://{host_part}:{port}?{}", params.join("&"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_valid_mac_and_rejects_invalid() {
        assert_eq!(
            format_mac(&[0xaa, 0xbb, 0xcc, 0x01, 0x23, 0x45]).as_deref(),
            Some("AA:BB:CC:01:23:45")
        );
        assert_eq!(format_mac(&[0, 0, 0, 0, 0, 0]), None);
        assert_eq!(format_mac(&[0xFF; 6]), None);
        assert_eq!(format_mac(&[1, 2, 3]), None);
    }

    #[test]
    fn selects_matching_preferred_ip_or_best_lan_ethernet_adapter() {
        let candidates = vec![
            AdapterCandidate {
                ipv4s: vec![Ipv4Addr::new(169, 254, 10, 5)],
                mac: "11:11:11:11:11:11".into(),
                if_type: IF_TYPE_ETHERNET_CSMACD,
                oper_up: true,
            },
            AdapterCandidate {
                ipv4s: vec![Ipv4Addr::new(192, 168, 1, 20)],
                mac: "22:22:22:22:22:22".into(),
                if_type: IF_TYPE_IEEE80211,
                oper_up: true,
            },
            AdapterCandidate {
                ipv4s: vec![Ipv4Addr::new(192, 168, 1, 10)],
                mac: "33:33:33:33:33:33".into(),
                if_type: IF_TYPE_ETHERNET_CSMACD,
                oper_up: true,
            },
            AdapterCandidate {
                ipv4s: vec![Ipv4Addr::new(10, 0, 0, 5)],
                mac: "44:44:44:44:44:44".into(),
                if_type: IF_TYPE_ETHERNET_CSMACD,
                oper_up: false,
            },
        ];

        assert_eq!(
            select_best_adapter(&candidates, None),
            (
                Some(Ipv4Addr::new(192, 168, 1, 10)),
                Some("33:33:33:33:33:33".into())
            )
        );
        assert_eq!(
            select_best_adapter(&candidates, Some(Ipv4Addr::new(192, 168, 1, 20))),
            (
                Some(Ipv4Addr::new(192, 168, 1, 20)),
                Some("22:22:22:22:22:22".into())
            )
        );
    }

    #[test]
    fn builds_pairing_uri_with_encoded_parameters() {
        let uri = build_pairing_uri(
            "192.168.1.10",
            9876,
            "tok+1/2",
            Some("AA:BB:CC"),
            Some("00:11:22:33:44:55"),
            Some("Gaming PC"),
            true,
        );
        assert_eq!(
            uri,
            "winbridge://192.168.1.10:9876?name=Gaming%20PC&token=tok%2B1%2F2&fp=AA%3ABB%3ACC&mac=00%3A11%3A22%3A33%3A44%3A55&tls=1"
        );
    }
}
