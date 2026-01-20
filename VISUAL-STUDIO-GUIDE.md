# 📘 Hướng dẫn build OBS Studio với Visual Studio

## 🎯 Build hoàn chỉnh OBS với Custom Virtual Camera

---

## PHƯƠNG PHÁP 1: Dùng CMake GUI (DỄ NHẤT) ⭐

### Bước 1: Chuẩn bị

1. **Tải OBS source code** (nếu chưa có):
   ```cmd
   git clone https://github.com/vibecoder11200/obs-studio.git
   cd obs-studio
   ```

2. **Cài đặt prerequisites** (nếu chưa có):

   Tải và cài các thứ sau:
   - **CMake** - https://cmake.org/download/
   - **Git** - https://git-scm.com/download/win
   - **Visual Studio 2022** (hoặc 2019) với workloads:
     - ✅ Desktop development with C++
     - ✅ Windows 10/11 SDK

### Bước 2: Tải Dependencies (TỰ ĐỘNG)

1. Mở **PowerShell** trong thư mục obs-studio
2. Chạy:

   ```powershell
   # Windows x64
   .\CI\prepare-windows-env.ps1

   # Hoặc nếu không có script:
   mkdir build_x64
   cd build_x64
   cmake -G "Visual Studio 17 2022" -A x64 ..
   ```

   CMake sẽ tự động tải dependencies từ internet (~2-3 GB)

### Bước 3: Mở Visual Studio

1. Vào thư mục `build_x64`
2. Tìm file **`OBS-STUDIO.sln`**
3. **Double-click** để mở trong Visual Studio

### Bước 4: Cấu hình build

1. Ở thanh công cụ trên cùng:
   - **Solution Configuration**: Chọn `RelWithDebInfo` hoặc `Release`
   - **Solution Platform**: Chọn `x64`

2. Right-click vào solution → **Properties**:
   - Configuration: `RelWithDebInfo`
   - Platform: `x64`
   - OK

### Bước 5: Build

1. Menu **Build → Build Solution** (hoặc press **F7**)
2. Chờ... (tùy máy, 10-30 phút)
3. Kiểm tra **Output Window** xem có lỗi không

### Bước 6: Tìm output

Sau khi build thành công, file sẽ ở:

```
C:\path\to\obs-studio\build_x64\rundir\RelWithDebInfo\
```

Chạy file **`obs64.exe`** để test!

---

## PHƯƠNG PHÁP 2: Dùng Command Line + Visual Studio (ĐỀ XUẤN)

### Bước 1: Generate Solution với CMake

Mở **Developer Command Prompt for VS 2022**:

```cmd
# Vào thư mục obs-studio
cd C:\dev\obs-studio

# Tạo build directory
mkdir build_x64
cd build_x64

# Generate solution với custom GUID
cmake -G "Visual Studio 17 2022" -A x64 ^
  -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
  -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB ^
  -DENABLE_BROWSER=OFF ^
  -DENABLE_VLC=OFF ^
  ..

# Mở solution trong Visual Studio
start obs-studio.sln
```

### Bước 2: Trong Visual Studio

1. Solution mở ra → Chờ Visual Studio load projects
2. Set **Startup Project**:
   - Right-click `OBS-Studio` → **Set as Startup Project**
3. Build configuration:
   - Chọn `RelWithDebInfo`
   - Chọn `x64`
4. **F5** để debug hoặc **Ctrl+Shift+B** để build

### Bước 3: Run

Nhấn **F5** hoặc click **Local Windows Debugger** (nút Play màu xanh)

OBS sẽ chạy với **Logitech HD Pro Webcam C920** Virtual Camera! 🎉

---

## PHƯƠNG PHÁP 3: Build Installer (HOÀN CHỈNH NHẤT) 💿

### Bước 1: Build OBS

Làm theo **Phương pháp 1** hoặc **2**

### Bước 2: Tạo installer

1. Trong Visual Studio, mở solution
2. Right-click vào **`PACKAGE`** project
3. **Build** chỉ project này
4. Installer sẽ được tạo ở:

   ```
   build_x64\package\obs-studio-*.exe
   ```

### Bước 3: Cài đặt

Chạy file `.exe` vừa tạo → OBS sẽ được cài đặt với custom Virtual Camera!

---

## 🎨 TÙY CHỌN BUILD CƠ BẢN

Trong Visual Studio, bạn có thể chọn build哪些 gì:

### Chỉ build Virtual Camera Module

1. Solution Explorer → Tìm `obs-virtualcam`
2. Right-click → **Build**
3. DLL ở: `build_x64\obs-plugins\64bit\obs-virtualcam-module.dll`

### Build core OBS (không có browser)

```cmd
cmake -G "Visual Studio 17 2022" -A x64 ^
  -DENABLE_BROWSER=OFF ^
  -DENABLE_VLC=OFF ^
  -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB ^
  ..
```

### Build đầy đủ (tất cả features)

```cmd
cmake -G "Visual Studio 17 2022" -A x64 ^
  -DENABLE_BROWSER=ON ^
  -DENABLE_VLC=ON ^
  -DENABLE_SCRIPTING=ON ^
  -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB ^
  ..
```

---

## 🔧 TROUBLESHOOTING

### Lỗi: "Cannot open include file"

**Nguyên nhân:** Dependencies chưa được tải
**Giải pháp:** Chạy lại CMake, để nó tải dependencies

### Lỗi: "LINK : fatal error LNK1181"

**Nguyên nhân:** Đường dẫn quá dài
**Giải pháp:**
- Di chuyển thư mục obs-studio gần root hơn (C:\obs-studio)
- Hoặc enable "Long paths" trong Windows

### Lỗi: "MSB8040"

**Nguyên nhân:** Visual Studio không tìm thấy Windows SDK
**Giải pháp:**
- Mở Visual Studio Installer
- Modify → Install Windows 10/11 SDK

### Build thành công nhưng Virtual Camera không xuất hiện

**Kiểm tra:**
1. File `virtualcam-module.cpp` đã có tên "Logitech HD Pro Webcam C920"?
2. GUID đã được set đúng?
3. Chạy OBS as Administrator?

---

## 📊 File OUTPUT sau khi build

```
build_x64/
├── rundir/RelWithDebInfo/          ← OBS executable và dependencies
│   ├── obs64.exe                   ← Main executable
│   ├── obs-browser-page.exe        ← Browser source
│   └── ...
├── obs-plugins/64bit/              ← Plugins
│   ├── obs-virtualcam-module.dll   ← Custom Virtual Camera! ✅
│   └── ...
└── package/                        ← Installer (nếu build package)
    └── obs-studio-*.exe            ← Final installer
```

---

## ✅ CHECKLIST TRƯỚC KHI BUILD

- [ ] Visual Studio 2019/2022 đã cài
- [ ] Windows 10/11 SDK đã cài
- [ ] CMake đã cài
- [ ] Git đã cài
- [ ] Disk space còn ít nhất 10 GB
- [ ] Internet connection (để tải dependencies)
- [ ] File `CMakePresets.json` đã có GUID mới
- [ ] File `virtualcam-module.cpp` đã có tên mới

---

## 🎯 CÁCH BUILD NHANH NHẤT (3 LỆNH)

```cmd
# Mở "Developer Command Prompt for VS 2022"
cd C:\obs-studio
mkdir build_x64 && cd build_x64
cmake -G "Visual Studio 17 2022" -A x64 -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB ..
start obs-studio.sln
```

Rồi trong Visual Studio: **Ctrl+Shift+B** (Build)

---

## 💡 TIPS

1. **Lần đầu build sẽ lâu** (20-30 phút) vì phải tải dependencies
2. **Lần sau sẽ nhanh** (5-10 phút) nhờ cache
3. **Nên build RelWithDebInfo** thay vì Release để dễ debug
4. **Có thể disable browser/vlc** để build nhanh hơn
5. **Disk space:** Cần ~10-15 GB free

---

## 📞 Cần hỗ trợ?

Nếu bị lỗi:
1. Chụp màn hình Output Window
2. Copy error message
3. Gửi lại

Tôi sẽ giúp fix! 🚀
