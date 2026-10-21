// Collab.Native.cs - Windows containment interop for the collaboration runner.
// Compiled at runtime with Add-Type (no installation, no external packages).
//
// Responsibilities:
//   * create a Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
//   * launch a child process SUSPENDED with hidden window and anonymous-pipe
//     stdio, so the caller can assign it to the Job Object BEFORE the child
//     gets any chance to spawn descendants (closes the launch race)
//   * resume the primary thread, wait, read job-object accounting, terminate
//     the owned root process through its retained handle (immune to PID reuse)
//
// The command line is assembled with the documented Windows quoting algorithm
// and passed straight to CreateProcessW. No shell (cmd.exe / powershell -Command)
// is ever involved, so no shell interpolation can occur.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;
using System.Text.RegularExpressions;

namespace Collab.Interop
{
    public sealed class LaunchResult
    {
        public IntPtr ProcessHandle = IntPtr.Zero;
        public IntPtr ThreadHandle = IntPtr.Zero;
        public int ProcessId;
        public int ThreadId;
        public DateTime? CreationTimeUtc;
        public long OutputBytes { get { return (Stdout == null ? 0 : Stdout.Bytes) + (Stderr == null ? 0 : Stderr.Bytes); } }
        public int Redactions { get { return (Stdout == null ? 0 : Stdout.Redactions) + (Stderr == null ? 0 : Stderr.Redactions); } }
        internal PipeCapture Stdout;
        internal PipeCapture Stderr;
        public string Error = string.Empty;
        public bool Ok { get { return ProcessHandle != IntPtr.Zero; } }
    }

    // Only scrubbed complete lines reach disk. Decoder and carry persist across
    // reads; oversized lines are suppressed through their newline, never split.
    internal sealed class PipeCapture : IDisposable
    {
        internal IntPtr Handle;
        internal long Bytes;
        internal int Redactions;
        private readonly StreamWriter sink;
        private readonly Decoder decoder = Encoding.UTF8.GetDecoder();
        private readonly StringBuilder carry = new StringBuilder();
        private bool suppressLine, privateKey;
        internal PipeCapture(IntPtr handle, string path)
        {
            Handle = handle;
            sink = new StreamWriter(path, false, new UTF8Encoding(false));
            sink.AutoFlush = true;
        }
        internal void Accept(byte[] bytes, int count, bool final)
        {
            Bytes += count;
            char[] chars = new char[count + 4];
            int length = decoder.GetChars(bytes, 0, count, chars, 0, final);
            for (int i = 0; i < length; i++)
            {
                if (!suppressLine) carry.Append(chars[i]);
                if (chars[i] == '\n') { FlushLine(); suppressLine = false; }
                else if (carry.Length > 1048576) { carry.Clear(); suppressLine = true; Redactions++; sink.Write("[REDACTED oversized line]\n"); }
            }
            if (final && carry.Length > 0) FlushLine();
        }
        private void FlushLine()
        {
            string text = carry.ToString(); carry.Clear();
            if (text.Contains("-----BEGIN") && text.Contains("PRIVATE KEY-----")) { privateKey = true; Redactions++; }
            if (privateKey)
            {
                if (text.Contains("-----END") && text.Contains("PRIVATE KEY-----")) privateKey = false;
                sink.Write("[REDACTED private key]\n"); return;
            }
            string[] patterns = {
                @"(?i)\bsk-[A-Za-z0-9_\-]{8,}",
                @"(?i)(\bbearer\s+)([A-Za-z0-9._\-]{10,})",
                @"(?i)((?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|refresh[_-]?token|password|passwd|client[_-]?secret|secret|token|authorization|x-api-key|anthropic_auth_token|openai_api_key|deepseek_api_key|zcode_[a-z_]*key)[""']?\s*[:=]\s*[""']?)([^\s""',;}\]]{8,})"
            };
            string[] replacements = { "sk-«REDACTED»", "$1«REDACTED»", "$1«REDACTED»" };
            for (int i = 0; i < patterns.Length; i++)
            {
                Redactions += Regex.Matches(text, patterns[i]).Count;
                text = Regex.Replace(text, patterns[i], replacements[i]);
            }
            sink.Write(text);
        }
        public void Dispose() { try { sink.Dispose(); } finally { Native.Close(Handle); Handle = IntPtr.Zero; } }
    }

    public sealed class JobAccounting
    {
        public bool Ok;
        public string Error = string.Empty;
        public uint ActiveProcesses;
        public uint TotalProcesses;
        public uint TotalTerminatedProcesses;
    }

    public static class Native
    {
        private static readonly Dictionary<IntPtr, LaunchResult> captures = new Dictionary<IntPtr, LaunchResult>();
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SECURITY_ATTRIBUTES sa, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool PeekNamedPipe(IntPtr pipe, IntPtr buffer, uint size, IntPtr read, out uint available, IntPtr left);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadFile(IntPtr pipe, byte[] buffer, uint size, out uint read, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        public static bool TerminateOwned(int pid, DateTime createdUtc, out string error)
        {
            error = string.Empty;
            IntPtr process = OpenProcess(0x1001, false, pid);
            if (process == IntPtr.Zero) { error = LastError("OpenProcess failed"); return false; }
            try
            {
                long created, exited, kernel, user;
                if (!GetProcessTimes(process, out created, out exited, out kernel, out user) || DateTime.FromFileTimeUtc(created) != createdUtc.ToUniversalTime())
                { error = "process creation time mismatch or unavailable"; return false; }
                return Terminate(process, 42, out error);
            }
            finally { CloseHandle(process); }
        }
        public static bool TerminateJob(IntPtr job, uint exitCode, out string error)
        {
            error = string.Empty;
            if (!TerminateJobObject(job, exitCode)) { error = LastError("TerminateJobObject failed"); return false; }
            return true;
        }
        public static void DrainOutput(LaunchResult launch, bool final)
        {
            foreach (PipeCapture capture in new [] { launch.Stdout, launch.Stderr })
            {
                if (capture == null || capture.Handle == IntPtr.Zero) continue;
                uint available, read;
                int budget = final ? 4194304 : 262144;
                while (budget > 0 && PeekNamedPipe(capture.Handle, IntPtr.Zero, 0, IntPtr.Zero, out available, IntPtr.Zero) && available > 0)
                {
                    byte[] buffer = new byte[Math.Min(available, 65536u)];
                    if (!ReadFile(capture.Handle, buffer, (uint)buffer.Length, out read, IntPtr.Zero) || read == 0) break;
                    capture.Accept(buffer, (int)read, false); budget -= (int)read;
                }
                if (final) capture.Accept(new byte[0], 0, true);
            }
        }
        private const uint CREATE_SUSPENDED = 0x00000004;
        private const uint CREATE_NO_WINDOW = 0x08000000;
        private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;

        private const int STARTF_USESHOWWINDOW = 0x00000001;
        private const int STARTF_USESTDHANDLES = 0x00000100;
        private const short SW_HIDE = 0;

        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint CREATE_ALWAYS = 2;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;

        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const int JobObjectExtendedLimitInformation = 9;
        private const int JobObjectBasicAccountingInformation = 1;

        private const uint WAIT_OBJECT_0 = 0x00000000;
        private const uint WAIT_TIMEOUT = 0x00000102;

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
        {
            public long TotalUserTime;
            public long TotalKernelTime;
            public long ThisPeriodTotalUserTime;
            public long ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount;
            public uint TotalProcesses;
            public uint ActiveProcesses;
            public uint TotalTerminatedProcesses;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength, out uint lpReturnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcessW(
            string lpApplicationName,
            StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            bool bInheritHandles,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            string lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFileW(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            ref SECURITY_ATTRIBUTES lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);
        private const uint HANDLE_FLAG_INHERIT = 0x00000001;
        private const int STILL_ACTIVE = 259;

        private static string LastError(string prefix)
        {
            int code = Marshal.GetLastWin32Error();
            string message;
            try { message = new Win32Exception(code).Message; }
            catch { message = "unknown"; }
            return prefix + " (win32=" + code.ToString() + ": " + message + ")";
        }

        /// <summary>Creates a Job Object that kills every member when the last handle closes.</summary>
        public static IntPtr CreateKillOnCloseJob(out string error)
        {
            error = string.Empty;
            IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                error = LastError("CreateJobObject failed");
                return IntPtr.Zero;
            }
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    error = LastError("SetInformationJobObject(KILL_ON_JOB_CLOSE) failed");
                    CloseHandle(job);
                    return IntPtr.Zero;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
            return job;
        }

        public static JobAccounting QueryJob(IntPtr job)
        {
            JobAccounting result = new JobAccounting();
            if (job == IntPtr.Zero)
            {
                result.Error = "job handle is null";
                return result;
            }
            int size = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                uint returned;
                if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, buffer, (uint)size, out returned))
                {
                    result.Error = LastError("QueryInformationJobObject failed");
                    return result;
                }
                JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info =
                    (JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(buffer, typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                result.ActiveProcesses = info.ActiveProcesses;
                result.TotalProcesses = info.TotalProcesses;
                result.TotalTerminatedProcesses = info.TotalTerminatedProcesses;
                result.Ok = true;
                return result;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static bool AssignToJob(IntPtr job, IntPtr process, out string error)
        {
            error = string.Empty;
            if (job == IntPtr.Zero || process == IntPtr.Zero)
            {
                error = "job or process handle is null";
                return false;
            }
            if (!AssignProcessToJobObject(job, process))
            {
                error = LastError("AssignProcessToJobObject failed");
                return false;
            }
            return true;
        }

        /// <summary>Builds a Windows command line from argv using the documented quoting rules.</summary>
        public static string BuildCommandLine(string application, string[] arguments)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append(QuoteArgument(application));
            if (arguments != null)
            {
                for (int i = 0; i < arguments.Length; i++)
                {
                    sb.Append(' ');
                    sb.Append(QuoteArgument(arguments[i]));
                }
            }
            return sb.ToString();
        }

        public static string QuoteArgument(string argument)
        {
            if (argument == null) return "\"\"";
            if (argument.Length > 0 && argument.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
                return argument;

            StringBuilder sb = new StringBuilder();
            sb.Append('"');
            int backslashes = 0;
            for (int i = 0; i < argument.Length; i++)
            {
                char c = argument[i];
                if (c == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (c == '"')
                {
                    sb.Append('\\', backslashes * 2 + 1);
                    sb.Append('"');
                    backslashes = 0;
                    continue;
                }
                if (backslashes > 0)
                {
                    sb.Append('\\', backslashes);
                    backslashes = 0;
                }
                sb.Append(c);
            }
            if (backslashes > 0) sb.Append('\\', backslashes * 2);
            sb.Append('"');
            return sb.ToString();
        }

        private static string BuildEnvironmentBlock(IDictionary<string, string> overrides)
        {
            SortedDictionary<string, string> map = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
            {
                string key = entry.Key as string;
                if (string.IsNullOrEmpty(key) || key[0] == '=') continue;
                map[key] = entry.Value as string ?? string.Empty;
            }
            if (overrides != null)
            {
                foreach (KeyValuePair<string, string> pair in overrides)
                {
                    if (string.IsNullOrEmpty(pair.Key) || pair.Key.IndexOf('=') >= 0) continue;
                    map[pair.Key] = pair.Value ?? string.Empty;
                }
            }
            StringBuilder sb = new StringBuilder();
            foreach (KeyValuePair<string, string> pair in map)
            {
                sb.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');
            }
            sb.Append('\0');
            return sb.ToString();
        }

        /// <summary>
        /// Starts the child SUSPENDED with hidden window and anonymous-pipe stdio.
        /// The caller must assign it to a Job Object and then call Resume().
        /// </summary>
        public static LaunchResult StartSuspended(
            string application,
            string[] arguments,
            string workingDirectory,
            IDictionary<string, string> environmentOverrides,
            string stdoutPath,
            string stderrPath)
        {
            LaunchResult result = new LaunchResult();
            if (string.IsNullOrEmpty(application))
            {
                result.Error = "application path is empty";
                return result;
            }
            if (string.IsNullOrEmpty(workingDirectory))
            {
                result.Error = "working directory is empty";
                return result;
            }

            SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
            sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            sa.bInheritHandle = true;
            sa.lpSecurityDescriptor = IntPtr.Zero;

            IntPtr stdinHandle = CreateFileW("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, ref sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
            if (stdinHandle == INVALID_HANDLE_VALUE)
            {
                result.Error = LastError("CreateFile(NUL) failed");
                return result;
            }
            IntPtr stdoutHandle = IntPtr.Zero, stderrHandle = IntPtr.Zero;
            IntPtr stdoutRead = IntPtr.Zero, stderrRead = IntPtr.Zero;
            if (!CreatePipe(out stdoutRead, out stdoutHandle, ref sa, 65536) ||
                !CreatePipe(out stderrRead, out stderrHandle, ref sa, 65536) ||
                !SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0) ||
                !SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0))
            {
                result.Error = LastError("anonymous pipe setup failed");
                Close(stdinHandle); Close(stdoutHandle); Close(stderrHandle); Close(stdoutRead); Close(stderrRead);
                return result;
            }

            IntPtr environmentBlock = IntPtr.Zero;
            PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
            try
            {
                result.Stdout = new PipeCapture(stdoutRead, stdoutPath); stdoutRead = IntPtr.Zero;
                result.Stderr = new PipeCapture(stderrRead, stderrPath); stderrRead = IntPtr.Zero;
                STARTUPINFO si = new STARTUPINFO();
                si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
                si.wShowWindow = SW_HIDE;
                si.hStdInput = stdinHandle;
                si.hStdOutput = stdoutHandle;
                si.hStdError = stderrHandle;

                string block = BuildEnvironmentBlock(environmentOverrides);
                environmentBlock = Marshal.StringToHGlobalUni(block);

                StringBuilder commandLine = new StringBuilder(BuildCommandLine(application, arguments));
                uint flags = CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT;

                bool ok = CreateProcessW(
                    application,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    flags,
                    environmentBlock,
                    workingDirectory,
                    ref si,
                    out pi);

                if (!ok)
                {
                    result.Error = LastError("CreateProcessW failed for " + application);
                    return result;
                }

                long created, exited, kernel, user;
                if (GetProcessTimes(pi.hProcess, out created, out exited, out kernel, out user))
                    result.CreationTimeUtc = DateTime.FromFileTimeUtc(created);
                result.ProcessHandle = pi.hProcess;
                result.ThreadHandle = pi.hThread;
                result.ProcessId = pi.dwProcessId;
                result.ThreadId = pi.dwThreadId;
                lock (captures) captures[result.ProcessHandle] = result;
                return result;
            }
            catch (Exception ex)
            {
                result.Error = "StartSuspended exception: " + ex.Message;
                if (pi.hProcess != IntPtr.Zero) { TerminateProcess(pi.hProcess, 31); WaitForSingleObject(pi.hProcess, 5000); CloseHandle(pi.hProcess); }
                result.ProcessHandle = IntPtr.Zero;
                if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
                return result;
            }
            finally
            {
                if (environmentBlock != IntPtr.Zero) Marshal.FreeHGlobal(environmentBlock);
                CloseHandle(stdinHandle);
                CloseHandle(stdoutHandle);
                CloseHandle(stderrHandle);
                Close(stdoutRead); Close(stderrRead);
                if (!result.Ok) { if (result.Stdout != null) result.Stdout.Dispose(); if (result.Stderr != null) result.Stderr.Dispose(); }
            }
        }

        public static bool Resume(IntPtr threadHandle, out string error)
        {
            error = string.Empty;
            if (threadHandle == IntPtr.Zero)
            {
                error = "thread handle is null";
                return false;
            }
            uint previous = ResumeThread(threadHandle);
            if (previous == 0xFFFFFFFF)
            {
                error = LastError("ResumeThread failed");
                return false;
            }
            return true;
        }

        /// <summary>Waits for a handle. Returns "signaled", "timeout" or "error".</summary>
        public static string WaitFor(IntPtr handle, int milliseconds)
        {
            LaunchResult capture;
            lock (captures) captures.TryGetValue(handle, out capture);
            if (capture != null) DrainOutput(capture, false);
            uint code = WaitForSingleObject(handle, (uint)milliseconds);
            if (capture != null) DrainOutput(capture, false);
            if (code == WAIT_OBJECT_0) return "signaled";
            if (code == WAIT_TIMEOUT) return "timeout";
            return "error";
        }

        public static bool TryGetExitCode(IntPtr processHandle, out int exitCode)
        {
            exitCode = -1;
            uint code;
            if (!GetExitCodeProcess(processHandle, out code)) return false;
            if (code == STILL_ACTIVE) return false;
            exitCode = unchecked((int)code);
            return true;
        }

        /// <summary>Terminates the process through the retained handle (immune to PID reuse).</summary>
        public static bool Terminate(IntPtr processHandle, uint exitCode, out string error)
        {
            error = string.Empty;
            if (processHandle == IntPtr.Zero)
            {
                error = "process handle is null";
                return false;
            }
            if (!TerminateProcess(processHandle, exitCode))
            {
                error = LastError("TerminateProcess failed");
                return false;
            }
            return true;
        }

        public static void Close(IntPtr handle)
        {
            LaunchResult capture;
            lock (captures) { captures.TryGetValue(handle, out capture); captures.Remove(handle); }
            try { if (capture != null) DrainOutput(capture, true); }
            finally
            {
                try { if (capture != null) { try { capture.Stdout.Dispose(); } finally { capture.Stderr.Dispose(); } } }
                finally { if (handle != IntPtr.Zero) CloseHandle(handle); }
            }
        }
    }
}
