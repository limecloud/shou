using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Reads only a requested process's current-directory descriptor and UTF-16 path.</summary>
internal static class WindowsProcessScope
{
    private static readonly UnicodeEncoding Unicode = new(false, false, true);

    internal static unsafe ProcessObservation Read(ProcessObservation observation, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        // PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | SYNCHRONIZE; never request write or debug rights.
        using var process = NativeMethods.OpenProcess(0x00100410, false, observation.ProcessId);
        if (process.IsInvalid) return observation;
        try
        {
            if (NativeMethods.WaitForProcess(process, 0) == 0) return observation with { Exited = true };
            var name = stackalloc char[32768];
            uint size = 32768;
            if (!NativeMethods.ProcessImageName(process, 0, (nint)name, ref size) || size is 0 or >= 32768) return observation;
            var image = new string(name, 0, (int)size);
            var basename = image[(image.LastIndexOf('\\') + 1)..];
            if (!string.Equals(basename, observation.ExecutableName, StringComparison.OrdinalIgnoreCase)) return observation;
            var basic = new NativeMethods.ProcessBasicInformation();
            if (NativeMethods.ProcessInformation(process, 0, (nint)(&basic), (uint)sizeof(NativeMethods.ProcessBasicInformation), out var returned) < 0 ||
                returned != sizeof(NativeMethods.ProcessBasicInformation) || basic.ProcessId != observation.ProcessId) return observation;
            nuint wow64 = 0;
            if (NativeMethods.ProcessInformation(process, 26, (nint)(&wow64), (uint)sizeof(nuint), out returned) < 0 || returned != sizeof(nuint)) return observation;
            var narrow = wow64 != 0;
            var peb = narrow ? wow64 : (nuint)basic.PebAddress;
            var parametersAddress = Add(peb, narrow ? 0x10u : 0x20u);
            var parametersPointer = ReadMemory(process, parametersAddress, narrow ? 4 : 8, token);
            var parameters = Pointer(parametersPointer, narrow);
            // Normalized RTL_USER_PROCESS_PARAMETERS has an absolute current-directory string pointer.
            var header = ReadMemory(process, parameters, 16, token);
            var maximumBytes = BinaryPrimitives.ReadUInt32LittleEndian(header);
            var actualBytes = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
            if (actualBytes < (narrow ? 44 : 72) || actualBytes > maximumBytes || maximumBytes > 1_048_576 ||
                (BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8)) & 1) == 0) return observation;
            var descriptorAddress = Add(parameters, narrow ? 0x24u : 0x38u);
            var descriptor = ReadMemory(process, descriptorAddress, narrow ? 8 : 16, token);
            var length = BinaryPrimitives.ReadUInt16LittleEndian(descriptor);
            var maximum = BinaryPrimitives.ReadUInt16LittleEndian(descriptor.AsSpan(2));
            if (length is 0 or > 65520 || length % 2 != 0 || maximum < length || maximum > 65534) return observation;
            var buffer = Pointer(descriptor.AsSpan(narrow ? 4 : 8), narrow);
            var pathBytes = ReadMemory(process, buffer, length, token);
            var path = WindowsPath.Parse(Unicode.GetString(pathBytes));
            using var pinned = WindowsFileSystem.PinPath(path);
            var directory = WindowsFileSystem.ReadEntry(path, pinned.Final);
            if (directory.Kind != EntryKind.Directory) return observation;
            // A changing process descriptor or directory is uncertainty, even when its path still looks familiar.
            if (!ReadMemory(process, parametersAddress, parametersPointer.Length, token).AsSpan().SequenceEqual(parametersPointer) ||
                !ReadMemory(process, descriptorAddress, descriptor.Length, token).AsSpan().SequenceEqual(descriptor) ||
                !ReadMemory(process, buffer, pathBytes.Length, token).AsSpan().SequenceEqual(pathBytes) ||
                WindowsFileSystem.ReadEntry(path, pinned.Final) != directory) return observation;
            token.ThrowIfCancellationRequested();
            return NativeMethods.WaitForProcess(process, 0) switch
            {
                258 => observation with { WorkingDirectory = directory }, // WAIT_TIMEOUT: the opened process is still live.
                0 => observation with { Exited = true },
                _ => observation
            };
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or ArgumentException or OverflowException)
        { return NativeMethods.WaitForProcess(process, 0) == 0 ? observation with { Exited = true } : observation; }
    }

    private static unsafe byte[] ReadMemory(SafeFileHandle process, nuint address, int length, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        _ = Add(address, (uint)length);
        var bytes = new byte[length];
        fixed (byte* buffer = bytes)
            if (!NativeMethods.ReadProcessMemory(process, checked((nint)address), (nint)buffer, (nuint)length, out var read) || read != (nuint)length)
                throw new ShouException("process_scope_unavailable", "The process current directory could not be read.");
        return bytes;
    }

    private static nuint Pointer(ReadOnlySpan<byte> bytes, bool narrow) =>
        Add(narrow ? BinaryPrimitives.ReadUInt32LittleEndian(bytes) : checked((nuint)BinaryPrimitives.ReadUInt64LittleEndian(bytes)), 0);

    private static nuint Add(nuint pointer, uint offset)
    {
        var result = checked(pointer + offset);
        if (pointer < 0x10000 || result > 0x0000FFFFFFFFFFFF) throw new ShouException("process_scope_unavailable", "The process current-directory pointer is unsupported.");
        return result;
    }
}
