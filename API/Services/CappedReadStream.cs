namespace BookClubApi.Services;

/// #204 — a read-only pass-through that refuses to yield more than `maxBytes`. The file-body send
/// streams the request straight into blob storage; Content-Length is checked first, but a chunked
/// request declares none, so the cap has to hold while streaming too. Exceeding it throws
/// <see cref="ExceededException"/>, which the storage SDK may surface wrapped — callers test with
/// <see cref="WasExceeded"/> rather than catching the type directly.
public sealed class CappedReadStream(Stream inner, long maxBytes) : Stream
{
    public sealed class ExceededException() : IOException("The upload is larger than allowed.");

    private long _read;

    public static bool WasExceeded(Exception? ex)
    {
        for (; ex is not null; ex = ex.InnerException)
        {
            if (ex is ExceededException) return true;
            if (ex is AggregateException agg && agg.InnerExceptions.Any(WasExceeded)) return true;
        }
        return false;
    }

    public override int Read(byte[] buffer, int offset, int count) => Count(inner.Read(buffer, offset, count));

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        => Count(await inner.ReadAsync(buffer, cancellationToken));

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        => ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    private int Count(int n)
    {
        _read += n;
        if (_read > maxBytes) throw new ExceededException();
        return n;
    }

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => _read; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
