# installer-zapret2-voidlinux

Installer cho [zapret2](https://github.com/bol-van/zapret2) trên **Void Linux**, tích hợp sẵn:

- `zapret2` với nftables/NFQUEUE và runit.
- `dnscrypt-proxy` dùng DoH qua Cloudflare.
- NetworkManager trỏ DNS của kết nối WAN về `127.0.0.1`.
- Backup và rollback tự động khi cài đặt thất bại.
- Kiểm tra checksum cho binary zapret2 và dnscrypt-proxy.

> Script được viết cho Void Linux x86_64, PID 1 là `runit`, NetworkManager và interface WAN mặc định `eno1`.

## Tính năng

- Cài zapret2 `v1.0.5.2` từ release chính thức.
- Cài dnscrypt-proxy `2.1.18` từ release chính thức.
- Xác minh SHA-256 của archive và các binary `ip2net`, `mdig`, `nfqws2`.
- Đảm bảo có user hệ thống `tpws` và `dnscrypt-proxy` (tạo nếu chưa tồn tại).
- Quản lý các service runit của zapret2, dnscrypt-proxy và nftables:
  - `/var/service/zapret2`
  - `/var/service/dnscrypt-proxy`
  - `/var/service/nftables`
- Tạo queue nftables với `QNUM=200`.
- Dùng profile DPI tối ưu cho HTTP, TLS và QUIC.
- Tự backup trước khi thay đổi `/opt/zapret2`, service, DNS, binary và cấu hình NetworkManager.
- Tự rollback nếu quá trình cài đặt hoặc kiểm tra live thất bại.
- Có chế độ kiểm tra không thay đổi hệ thống: `--check`.

## Yêu cầu hệ thống

| Yêu cầu | Giá trị mặc định |
|---|---|
| Hệ điều hành | Void Linux |
| Kiến trúc | `x86_64` |
| Init | `runit` là PID 1 |
| Trình quản lý mạng | NetworkManager |
| Interface WAN | `eno1` |
| Module kernel | `nft_queue`, `nfnetlink_queue` |
| Công cụ | `bash`, `curl`, `nft`, `nmcli`, `sv`, `tar`, `sha256sum` và các lệnh hệ thống cơ bản |

Nếu interface WAN không tên `eno1`, sửa biến `IFACE_WAN` trong `install-zapret2-void.sh` trước khi chạy.

## Cài đặt

### 1. Clone repository

```bash
git clone https://github.com/slimulv1/installer-zapret2-voidlinux.git
cd installer-zapret2-voidlinux
```

### 2. Kiểm tra script

Không nên chạy trực tiếp một script chưa đọc qua `curl | sudo`. Có thể kiểm tra cú pháp trước:

```bash
bash -n install-zapret2-void.sh
```

### 3. Chạy installer

```bash
chmod +x install-zapret2-void.sh
sudo ./install-zapret2-void.sh
```

Installer cần chạy bằng root và sẽ thay đổi DNS, nftables và service runit. Khi thay đổi DNS qua NetworkManager, kết nối mạng có thể bị ngắt trong vài giây.

Backup được lưu dưới:

```text
/etc/void-backup/zapret2-void-YYYYMMDD-HHMMSS-PID/
```

## Kiểm tra sau cài đặt

### Kiểm tra bằng installer

```bash
sudo ./install-zapret2-void.sh --check
```

Lệnh này kiểm tra binary, profile, service, bảng nftables, DNS nội bộ và route mặc định mà không thay đổi hệ thống.

### Kiểm tra service

```bash
sudo sv status zapret2
sudo sv status dnscrypt-proxy
sudo sv status nftables
```

### Kiểm tra nftables và DNS

```bash
sudo nft list table inet zapret2
sudo ss -lunt 'sport = :53'
```

Kết quả DNS mong đợi:

```text
127.0.0.1:53
```

### Kiểm tra HTTP/2 và TLS

```bash
curl --http2 --fail --location --output /dev/null https://example.com
```

Nếu `curl` được build với HTTP/3, có thể kiểm tra thêm:

```bash
curl --http3-only --fail --location --output /dev/null https://www.youtube.com
```

## Profile zapret2

Profile được ghi trong `write_config()` của installer và cài vào:

```text
/opt/zapret2/config
```

Các tham số chính:

```text
NFQWS2_PORTS_TCP=80,443
NFQWS2_PORTS_UDP=443
NFQWS2_TCP_PKT_OUT=20
NFQWS2_TCP_PKT_IN=1
NFQWS2_UDP_PKT_OUT=5
NFQWS2_UDP_PKT_IN=1
```

Chiến lược desync:

- HTTP: `http_hostcase:spell=hoSt`
- TLS: `multidisorder:pos=1,midsld`
- QUIC: `fake_default_quic` với `repeats=1:ip_ttl=2`

Profile dùng `--in-range=x`, tức chủ yếu xử lý gói đi, với giới hạn gói đầu cho TCP và UDP. `MODE_FILTER=none` được giữ để ưu tiên độ phủ rộng.

## DNS

`dnscrypt-proxy` lắng nghe chỉ trên loopback:

```text
127.0.0.1:53
```

Cấu hình mặc định:

- Resolver: Cloudflare DoH.
- `force_tcp=true`.
- `http3=false`.
- `ignore_system_dns=true`.
- Cache DNS bật.
- IPv6 resolver tắt.
- NetworkManager dùng `127.0.0.1` và bỏ qua DNS tự động.

Cấu hình nằm tại:

```text
/etc/dnscrypt-proxy.toml
```

Log dnscrypt-proxy:

```text
/var/log/dnscrypt-proxy.log
```

## Các file quan trọng

| Đường dẫn | Vai trò |
|---|---|
| `/opt/zapret2` | Binary, Lua và cấu hình zapret2 |
| `/opt/zapret2/config` | Profile đang chạy |
| `/etc/sv/zapret2` | Service runit của zapret2 |
| `/etc/sv/dnscrypt-proxy` | Service runit của dnscrypt-proxy |
| `/etc/sv/nftables` | Service runit nạp nftables |
| `/etc/nftables.conf` | Cấu hình nftables |
| `/etc/dnscrypt-proxy.toml` | Cấu hình dnscrypt-proxy |
| `/etc/modules-load.d/zapret2.conf` | Module nftables cần nạp khi boot |
| `/etc/void-backup` | Backup trước khi cài |

## Tùy chỉnh

Nếu muốn thử chiến lược khác:

1. Sao lưu `/opt/zapret2/config`.
2. Dùng `blockcheck2` từ zapret2 để thử trên đúng các website bị ảnh hưởng.
3. Cập nhật profile trong `write_config()` của `install-zapret2-void.sh`, không chỉ sửa file trong `/opt/zapret2`.
4. Chạy lại installer và kiểm tra bằng `--check`.

Việc sửa trực tiếp `/opt/zapret2/config` có thể bị ghi đè khi chạy lại installer.

## `--force`

```bash
sudo ./install-zapret2-void.sh --force
```

Chỉ dùng `--force` sau khi đã kiểm tra các file runit bị sửa tay. Tùy chọn này cho phép thay thế file đang tồn tại không khớp với file do installer quản lý; không nên dùng để ghi đè thay đổi tùy ý.

## Rollback và khôi phục

Installer tự tạo backup trước khi thay đổi và tự rollback khi gặp lỗi. Một số trạng thái được lưu gồm:

- `/opt/zapret2` trước khi thay thế.
- Service runit của zapret2 và dnscrypt-proxy.
- Cấu hình và binary dnscrypt-proxy.
- DNS và `ignore-auto-dns` của NetworkManager.
- File run/finish của nftables.
- Module nạp khi boot.
- Ruleset nftables, địa chỉ IP và route trước khi cài.

Installer không tự ghi đè bằng backup sau khi cài đặt đã thành công. Nếu cần khôi phục thủ công, hãy kiểm tra thư mục backup tương ứng trước khi thay đổi lại service hoặc NetworkManager.

## Xử lý sự cố

### `không phải Void Linux`

Kiểm tra:

```bash
cat /etc/os-release
```

### `PID 1 không phải runit`

Script cố ý yêu cầu runit làm PID 1 để quản lý service đúng cách.

### `interface WAN không tồn tại`

Kiểm tra tên interface:

```bash
ip -brief link
```

Sửa `IFACE_WAN=eno1` trong script nếu tên interface khác.

### `kernel không có module nft_queue` hoặc `nfnetlink_queue`

Kiểm tra kernel:

```bash
modinfo nft_queue
modinfo nfnetlink_queue
```

Cần dùng kernel có các module này.

### `dnscrypt-proxy chưa sẵn sàng`

```bash
sudo sv status dnscrypt-proxy
sudo ss -lunt 'sport = :53'
sudo /usr/bin/dnscrypt-proxy -check -config /etc/dnscrypt-proxy.toml
```

### Một website vẫn bị chặn

Có thể website bị chặn bởi DNS/IP, router, địa lý, tài khoản, CAPTCHA hoặc không hỗ trợ QUIC. zapret2 không thể bảo đảm bypass mọi website trong mọi trường hợp.

Nên kiểm tra riêng:

```bash
curl --http1.1 --fail --location --output /dev/null https://example.com
curl --http2 --fail --location --output /dev/null https://example.com
curl --tlsv1.2 --tls-max 1.2 --fail --location --output /dev/null https://example.com
```

Nếu `curl` hỗ trợ HTTP/3, kiểm tra thêm `--http3-only`.

## Lịch sử thay đổi

- `zapret2`: `v1.0.5.2`
- `dnscrypt-proxy`: `2.1.18`
- Profile HTTP/TLS/QUIC được cập nhật để giảm xử lý không cần thiết và giảm tải CPU.
- Bổ sung backup, rollback, retry runit và kiểm tra checksum.

## Nguồn tham khảo

- [zapret2 repository](https://github.com/bol-van/zapret2)
- [zapret2 manual](https://github.com/bol-van/zapret2/blob/master/docs/manual.en.md)
- [zapret2 release v1.0.5.2](https://github.com/bol-van/zapret2/releases/tag/v1.0.5.2)
- [dnscrypt-proxy repository](https://github.com/DNSCrypt/dnscrypt-proxy)
- [dnscrypt-proxy release 2.1.18](https://github.com/DNSCrypt/dnscrypt-proxy/releases/tag/2.1.18)
