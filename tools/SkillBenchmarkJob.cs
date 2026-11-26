using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ReflexCore.Measurement
{
    // Benchmark-only counters include the PowerShell fixture and terminated UIA workers.
    public sealed class SkillBenchmarkJob : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        struct Accounting {
            public long User, Kernel, PeriodUser, PeriodKernel;
            public uint Faults, TotalProcesses, ActiveProcesses, TerminatedProcesses;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct Limits {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcesses;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct Extended {
            public Limits Basic;
            public ulong Reads, Writes, Other, ReadBytes, WriteBytes, OtherBytes;
            public UIntPtr ProcessLimit, JobLimit, PeakProcess, PeakJob;
        }
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern SafeFileHandle CreateJobObject(IntPtr security, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool QueryInformationJobObject(SafeFileHandle job, int kind, out Accounting data, int size, IntPtr used);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool QueryInformationJobObject(SafeFileHandle job, int kind, out Extended data, int size, IntPtr used);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool TerminateJobObject(SafeFileHandle job, uint status);
        readonly SafeFileHandle handle;
        public SkillBenchmarkJob(Process root)
        {
            handle=CreateJobObject(IntPtr.Zero,null);
            if(handle.IsInvalid || !AssignProcessToJobObject(handle,root.Handle)){
                var error=new Win32Exception();handle.Dispose();throw error;
            }
        }
        public long CpuMicroseconds {get;private set;}
        public uint Processes {get;private set;}
        public ulong PeakCommitBytes {get;private set;}
        public void Sample()
        {
            Accounting a; Extended e;
            if(!QueryInformationJobObject(handle,1,out a,Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero) ||
               !QueryInformationJobObject(handle,9,out e,Marshal.SizeOf(typeof(Extended)),IntPtr.Zero))
                throw new Win32Exception();
            CpuMicroseconds=(a.User+a.Kernel)/10;
            Processes=a.TotalProcesses;
            PeakCommitBytes=e.PeakJob.ToUInt64();
        }
        public void Stop(){if(!TerminateJobObject(handle,1))throw new Win32Exception();}
        public void Dispose(){handle.Dispose();}
    }
}
