# 📖 Hướng dẫn cài đặt OBS Virtual Camera - Logitech Edition

## 🎯 Mục tiêu

Biến OBS Virtual Camera thành **"Logitech HD Pro Webcam C920"** trong Windows!

---

## 📋 Cách 1: Dùng máy Windows bất kỳ (KHUYÊN DÙNG) ⭐

### Bước 1: Tải code về

Mở **Git Bash** hoặc **Command Prompt** trên máy Windows:

```cmd
git clone https://github.com/vibecoder11200/obs-studio.git
cd obs-studio
```

### Bước 2: Chạy file build

Double-click vào file: **`QUICK_BUILD.bat`**

- Chỉ mất **3-5 phút**
- Tự động tải dependencies
- Tự động build
- Tự động tạo file DLL

### Bước 3: Cài đặt

```
1. Tìm file: build\RelWithDebInfo\lvc920x64.dll
2. Copy file này vào:
   C:\Program Files\obs-studio\obs-plugins\win-dshow\

3. Mở OBS (Run as Administrator)
4. Tools → Start Virtual Camera
5. Mở Device Manager
6. Tìm "Logitech HD Pro Webcam C920" ✅
```

---

## 📋 Cách 2: Net cafe hoặc máy bạn bè (CÓ THỂ LÀM TRONG 5 PHÚT)

Net cafe thường có máy Windows + GPU mạnh, build chỉ mất 2 phút!

### Tại net cafe:

```
1. Cắm USB vào
2. Mở cmd, gõ:
   cd USB_DRIVE_LETTER:\

3. Clone code:
   git clone https://github.com/vibecoder11200/obs-studio.git

4. Chạy build:
   cd obs-studio
   QUICK_BUILD.bat

5. Đợi 2-3 phút

6. Copy file DLL vào USB

7. Về nhà, cài vào máy mình!
```

---

## 📋 Cách 3: Build Tools cài đặt cực nhẹ

Nếu muốn build trên máy riêng (yếu cũng được):

### Cài những thứ CẦN THIẾT (tổng cộng < 4 GB):

**1. Visual Studio Build Tools** (2-3 GB)

- Download: https://aka.ms/vs/17/release/vs_BuildTools.exe
- Chạy installer
- Chỉ chọn: **"Desktop development with C++"**
- Install

**2. CMake** (50 MB)

- Download: https://github.com/Kitware/CMake/releases/download/v3.30.0/cmake-3.30.0-windows-x86_64.zip
- Giải nén vào `C:\cmake`
- Thêm vào PATH:
  - Search "Environment Variables" trên Windows
  - Click "Environment Variables"
  - Edit "Path"
  - Add: `C:\cmake\bin`

**3. Chạy build:**

```cmd
cd obs-studio
QUICK_BUILD.bat
```

---

## ❓ Câu hỏi thường gặp

### "Tôi không có máy Windows, chỉ có Linux, làm sao?"

**Trả lời:** Có 3 lựa chọn:

1. **Mượn máy Windows** 5 phút (net cafe, bạn bè, máy trường)
2. **Dùng máy ảo Windows** trên Linux (VirtualBox + Windows 11 free dev VM)
3. **Cloud Windows** (Azure có trial miễn phí)

### "Máy tôi yếu quá, build được không?"

**Trả lời:** ĐƯỢC! Chỉ build virtualcam module:
- RAM: 4 GB là đủ
- CPU: Dual core là đủ
- Thời gian: 5-7 phút
- Không cần GPU!

### "Có file DLL sẵn không để tôi tải về dùng luôn?"

**Trả lời:** Rất tiếc không có. Phải build từ source vì:
- Cần compile với GUID riêng
- Tên "Logitech HD Pro Webcam C920" được hardcode trong source
- DLL đã compile không thể edit được

### "Tôi có thể edit file DLL có sẵn không?"

**Trả lời:** KHÔNG. String đã được compile vào binary, không thể edit được.
Phải rebuild từ source code.

---

## 🎥 Đổi danh tính camera (Dialog Virtual Camera Identity)

Sau khi cài xong, bạn có thể đổi danh tính camera **không cần build lại**,
ngay trong OBS: mở **Controls → Virtual Camera** → bấm nút cấu hình
(*Virtual Camera Identity*).

**12 preset camera thật** (đã kiểm chứng VID/PID + định dạng serial của
camera thật):

- Logitech: C920, C922, C930e, BRIO Ultra HD, Brio 500
- Elgato Facecam
- Laptop built-in: ACER HD User Facing, HP TrueVision, Lenovo EasyCamera,
  Integrated_Webcam_HD (Dell), USB2.0 HD UVC WebCam, HD Camera (Quanta)

Chọn preset → dialog tự điền tên, VID/PID và **một serial ngẫu nhiên đúng
định dạng của camera đó** (nút *Regenerate* tạo serial mới; ô serial vẫn sửa
tay được). Bấm **Apply (UAC)** → duyệt câu hỏi Administrator → camera đổi
danh tính ở lần đăng ký kế tiếp. Mở dialog lần sau sẽ hiển thị danh tính
đang lưu — bấm Apply không đổi gì thì không có gì xoay vòng.

**Lệnh CLI:** `core\win-dshow\data\vcamctl.exe` — `get`, `set --name N
--vid HHHH --pid HHHH [--serial S | --generate]`, `reset`, `register`,
`unregister` (cần quyền Administrator).

**Serial tự động:** nếu chưa có serial nào được lưu, module tự tạo một
serial ngẫu nhiên khớp định dạng của VID/PID và lưu vào registry ở lần đăng
ký đầu tiên. `reset` xoá serial → lần đăng ký kế tiếp tạo serial mới hoàn
toàn (reset = thay camera vật lý mới). Serial tối đa 32 ký tự ASCII.

**Lưu ý khi nâng cấp:** bản cài từng lưu preset C920 cũ (pid `0825` sai) sẽ
được tự động sửa thành `082d` (pid thật của C920) ở lần đăng ký kế tiếp.

**Linux:** dialog cho chọn preset + tên camera (card label) và lưu vào
config; nhãn áp dụng ở lần khởi động virtual camera **kế tiếp** (không cần
khởi động lại OBS).

**Kiểm tra:** chạy công cụ audit kèm theo bản cài (`auxdata/vcam-audit/
Audit-VirtualCam.ps1 scan`) — cần PowerShell 7.

---

## 🎁 Files đã thay đổi

Khi build xong, bạn sẽ có file với:
- Tên hiển thị: **Logitech HD Pro Webcam C920**
- GUID riêng: **76692E1E-F28F-4DD6-9024-C3A999D30EFB**
- Không xung đột với OBS Virtual Camera gốc

---

## 📞 Cần giúp đỡ?

**GitHub:** https://github.com/vibecoder11200/obs-studio

**Files quan trọng:**
- `QUICK_BUILD.bat` - Script build tự động
- `VIRTUALCAM_README.md` - Hướng dẫn chi tiết tiếng Anh
- `build-virtualcam.bat` - Script build khác (chi tiết hơn)

---

## ✅ Checklist cài đặt

- [ ] Clone repository
- [ ] Cài Visual Studio Build Tools (nếu chưa có)
- [ ] Cài CMake (nếu chưa có)
- [ ] Chạy QUICK_BUILD.bat
- [ ] Copy file DLL
- [ ] Mở OBS as Administrator
- [ ] Start Virtual Camera
- [ ] Kiểm tra Device Manager → "Logitech HD Pro Webcam C920"

🎉 **Hoàn tất!**
