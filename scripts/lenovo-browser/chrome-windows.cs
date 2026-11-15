// chrome-windows.cs — lenovo の Chrome のウィンドウを数える・閉じる (lenovo-chrome-shim が使う)
//
// shim が接続のたびに lenovo の %TEMP% へコピーし、PowerShell から Add-Type -Path で読み込む。
// shim の中に書かないのは、lenovo-interactive-run に渡せるコマンドが 3,000 文字ほどで切れるため。
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace LB {
public static class W {
	delegate bool EnumProc(IntPtr h, IntPtr l);
	[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
	[DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
	[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
	[DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
	[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
	[DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);

	// Chrome のブラウザのウィンドウか (chrome.exe が持ち、クラス名が Chrome_WidgetWin_1)
	static bool IsChromeWindow(IntPtr h) {
		uint pid;
		GetWindowThreadProcessId(h, out pid);
		string name;
		try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { return false; }
		var c = new StringBuilder(64);
		GetClassName(h, c, 64);
		return name == "chrome" && c.ToString() == "Chrome_WidgetWin_1";
	}

	// 見えていて、タイトルのある Chrome のウィンドウのハンドルを全部返す
	public static long[] ChromeWindows() {
		var r = new List<long>();
		EnumWindows((h, l) => {
			if (IsWindowVisible(h) && GetWindowTextLength(h) > 0 && IsChromeWindow(h)) r.Add(h.ToInt64());
			return true;
		}, IntPtr.Zero);
		return r.ToArray();
	}

	// WM_CLOSE を送る (×ボタンを押したのと同じ閉じ方)。もう無ければ gone
	public static string Close(long hwnd) {
		var h = new IntPtr(hwnd);
		if (!IsWindow(h)) return "gone";
		if (!IsChromeWindow(h)) return "not-chrome";
		return PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero) ? "closed" : "post-failed";
	}
}
}
