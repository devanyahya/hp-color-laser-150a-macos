# Printer laser host-based HP di macOS

*(English: [README.md](README.md))*

HP tidak pernah merilis driver macOS untuk seri **HP Laser 10x/13x** dan
**HP Color Laser 15x/17x** — hanya Windows dan Linux. Printer ini host-based:
bahasanya SPL-C/QPDL dan tidak bisa mengolah PostScript atau PCL sendiri,
sehingga driver generik sama sekali tidak menghasilkan apa pun.

Proyek ini menjalankan **driver Linux resmi HP di dalam container**, sementara
**macOS tetap yang memegang koneksi USB**. Mencetak dari aplikasi apa pun ke
antrean printer biasa.

Diuji di macOS 26.3 (Apple Silicon) dengan HP Color Laser 150a.

```
Aplikasi
    │
    ▼
CUPS (macOS)  ──►  cgpdftoraster  ──►  rastertospl-remote          ← filter CUPS, /bin/bash
                                              │
                                    /Users/Shared/hp-uld           ← antrean berkas bersama
                                              │
                                   container: rastertospl          ← driver Linux HP, arm64 native
                                              │
                                          SPL / QPDL
                                              │
                                    backend usb macOS  ──►  printer
```

## Printer yang didukung

| Seri | Model | PPD |
|---|---|---|
| HP Laser 10x | 107a, 107w, 108a, 108w | `HP_Laser_10x_Series.ppd` |
| HP Laser MFP 13x | 135a, 135w, 137fnw | `HP_Laser_MFP_13x_Series.ppd` |
| HP Color Laser 15x | 150a, 150nw | `HP_Color_Laser_15x_Series.ppd` |
| HP Color Laser MFP 17x | 178nw, 179fnw | `HP_Color_Laser_MFP_17x_Series.ppd` |

Hanya mencetak. Fungsi scan pada model MFP tidak ditangani.

## Prasyarat

- macOS di Apple Silicon atau Intel
- Container runtime: Docker Desktop, Colima, atau Podman — harus menyala saat mencetak
- Hak administrator (filter dipasang di `/Library/Printers`)

## Pemasangan

```sh
git clone https://github.com/<anda>/hp-uld-macos.git
cd hp-uld-macos
./install.sh
```

Installer mendeteksi printer yang tercolok, mengunduh Unified Linux Driver
langsung dari `ftp.hp.com`, memverifikasi SHA-256-nya, membangun image container,
memasang filter dan PPD, membuat antrean, lalu menutup dengan uji konversi yang
**tidak memakai kertas**.

Opsi yang berguna: `--queue NAMA`, `--paper Letter`, `--uri URI` (kalau ada
beberapa printer), `--ppd BERKAS.ppd`, `--no-suppressor`. Lihat `./install.sh --help`.

Nyalakan **"Start Docker Desktop when you sign in"** supaya tetap jalan setelah
komputer di-restart.

```sh
./doctor.sh      # periksa tiap lapisan, tunjukkan mana yang rusak
./uninstall.sh   # hapus antrean, container, filter, PPD, LaunchDaemon
```

## Opsi cetak yang benar-benar berpengaruh

PPD dari HP menawarkan lebih banyak opsi daripada yang benar-benar dikerjakan
driver. Diukur pada Color Laser 15x dengan mengonversi halaman yang sama lalu
membandingkan byte hasilnya:

| Opsi | Berpengaruh | Catatan |
|---|---|---|
| `Quality=600x600_2` / `_1` | **ya** | Best / Normal |
| `BlackOptimization=False` | **ya** | hitam komposit, bukan K saja; abu-abu lebih halus |
| `secBrightness=0..100` | **ya** | 50 netral, makin kecil makin tebal |
| `secContrast=0..100` | **ya** | |
| `secSaturation=0..100` | **ya** | |
| `CyanRed` / `MagentaGreen` / `YellowBlue` | **ya** | keseimbangan warna, 0..100 |
| `Trapping=Off/Medium/Maximum` | **ya** | kecil |
| `EdgeEnhance=Off` | **ya** | `Normal` dan `Maximum` identik |
| `MediaType=...` | **ya** | mengirim `@PJL SET PAPERTYPE`, mengubah perilaku fuser |
| `Screen=Normal/Enhanced/Detailed` | **tidak** | output byte-identik |
| `secRGB=Standard/Vivid/Device/...` | **tidak** | output byte-identik |
| `TonerSaveMode=Save` | **tidak** | output byte-identik |
| `DocumentType=Photo/...` | **tidak** | bahkan tidak terdaftar sebagai opsi UI di PPD |

Contoh:

```sh
lp -d HP_Color_Laser_150 -o BlackOptimization=False -o secBrightness=40 berkas.pdf
```

## Batasan yang diketahui

- **Tidak ada status printer.** Kertas nyangkut, baki kosong, dan toner menipis
  tidak dilaporkan ke macOS. Kanal balik USB memang dibaca backend CUPS, tapi
  tidak ada yang menerjemahkan status SPL — CUPS hanya tahu datanya terkirim.
- **Container harus menyala.** Kalau mati, job langsung gagal dengan pesan jelas,
  bukan menggantung — filter memeriksa berkas heartbeat lebih dulu.
- **Tidak ada fungsi scan** untuk model MFP.

## Kenapa ini sulit

Empat perilaku macOS menggagalkan implementasi yang "seharusnya jalan", dan
semuanya gagal secara senyap. Dicatat di sini supaya orang berikutnya tidak perlu
menemukannya lagi dari nol.

1. **cupsd menjalankan filter dalam sandbox dan memblokir jaringan.** Versi awal
   mengirim raster ke container lewat `127.0.0.1`; `curl` gagal dengan exit 7
   dalam 0 ms padahal portnya jelas mendengarkan. Karena itu dipakai antrean berkas.
2. **`/bin/sh` dan `/usr/bin/python3` cuma shim.** Keduanya membaca
   `/private/var/select/…` yang tidak boleh dibuka user `_lp`. Filter dengan
   `#!/bin/sh` mati dengan `Operation not permitted` dan exit 126. Pakai `/bin/bash`.
3. **Filter tidak boleh di `/usr/local`.** Sandbox hanya mengizinkan lokasi driver
   resmi seperti `/Library/Printers`.
4. **`umask 0000` wajib di filter.** Berkas mode 0600 milik `_lp` tampak sebagai
   `-?????????` di dalam container, karena file-sharing Docker berjalan sebagai
   user login. Akibatnya job diam saja tanpa pesan error.

Dua jebakan lain yang perlu diketahui:

- **`ippusbd` mengunci interface USB.** Printer ini mengiklankan IPP-over-USB
  (class 7/1, protokol 4) di *alternate setting 1*, sehingga macOS menjalankan
  `/usr/libexec/ippusbd` begitu dicolok. Daemon itu tidak pernah berhasil
  memakainya — dialog Add Printer tetap meminta driver — tapi tetap memegang
  interface-nya, dan antrean jadi berstatus *"printer is offline"*. Bahkan `root`
  tidak bisa merebut interface itu lewat libusb, jadi `ipp-usb` dari OpenPrinting
  pun tidak menolong. Sebuah LaunchDaemon menghentikannya tiap 30 detik.
- **`lpadmin -m everywhere` tidak bisa dipakai dengan URI `usb://`.** CUPS 2.3
  menganggap bagian host sebagai nama jaringan dan gagal dengan
  `Unable to connect to "HP:0"`. `ipp2ppd` punya cacat yang sama.

## Legal

Repositori ini **tidak memuat kode HP**. `install.sh` mengunduh Unified Linux
Driver dari server HP sendiri saat pemasangan dan memverifikasi checksum-nya.
Binary dan PPD HP tetap tunduk pada lisensi HP; skrip di sini berlisensi MIT.

## Kontribusi

Laporan dari model lain di seri ini sangat ditunggu — sebutkan modelnya, versi
macOS, dan tempelkan keluaran `./doctor.sh`. Temuan soal pelaporan status
(menerjemahkan kanal balik SPL) akan menutup celah fungsional terbesar.
