using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace TheOptimiser.Services;

// Pure Ed25519 verification (RFC 8032, edwards25519, extended homogeneous coords). The BCL has
// no Ed25519 primitive, so update manifests are verified offline with this - the scheme minisign
// and eclean use. Ported from the PowerShell build; checked against the RFC 8032 test vectors.
public static class Ed25519
{
    private static readonly BigInteger P = BigInteger.Pow(2, 255) - 19;
    private static readonly BigInteger L = BigInteger.Pow(2, 252) + BigInteger.Parse("27742317777372353535851937790883648493");
    private static readonly BigInteger D;
    private static readonly BigInteger[] B;

    static Ed25519()
    {
        D = Mod(-121665 * Inv(121666));
        var by = Mod(4 * Inv(5));
        var bx = RecoverX(by, 0)!.Value;
        B = new[] { bx, by, BigInteger.One, Mod(bx * by) };
    }

    private static BigInteger Mod(BigInteger a) { var r = a % P; return r < 0 ? r + P : r; }
    private static BigInteger Inv(BigInteger a) => BigInteger.ModPow(Mod(a), P - 2, P);

    private static BigInteger? RecoverX(BigInteger y, int sign)   // point decompression
    {
        var y2 = Mod(y * y);
        var u = Mod(y2 - 1);
        var v = Mod(D * y2 + 1);
        var x2 = Mod(u * Inv(v));
        if (x2 == 0) return sign == 1 ? null : BigInteger.Zero;
        var x = BigInteger.ModPow(x2, (P + 3) / 8, P);                        // p = 5 (mod 8)
        if (Mod(x * x - x2) != 0) x = Mod(x * BigInteger.ModPow(2, (P - 1) / 4, P));   // * sqrt(-1)
        if (Mod(x * x - x2) != 0) return null;
        if ((int)(x % 2) != sign) x = Mod(-x);
        return x;
    }

    private static BigInteger[] AddPoints(BigInteger[] p, BigInteger[] q)   // twisted Edwards a=-1
    {
        var a = Mod((p[1] - p[0]) * (q[1] - q[0]));
        var b = Mod((p[1] + p[0]) * (q[1] + q[0]));
        var c = Mod(p[3] * 2 * D * q[3]);
        var dd = Mod(p[2] * 2 * q[2]);
        var e = b - a; var f = dd - c; var g = dd + c; var h = b + a;
        return new[] { Mod(e * f), Mod(g * h), Mod(f * g), Mod(e * h) };
    }

    private static BigInteger[] MulPoint(BigInteger s, BigInteger[] p)   // double-and-add, MSB first
    {
        var r = new[] { BigInteger.Zero, BigInteger.One, BigInteger.One, BigInteger.Zero };
        var bits = new List<int>();
        for (var k = s; k > 0; k /= 2) bits.Add((int)(k % 2));
        bits.Reverse();
        foreach (var bit in bits) { r = AddPoints(r, r); if (bit == 1) r = AddPoints(r, p); }
        return r;
    }

    private static BigInteger LE(byte[] b)
    {
        BigInteger acc = 0;
        for (int i = b.Length - 1; i >= 0; i--) acc = acc * 256 + b[i];
        return acc;
    }

    public static bool Verify(byte[] pub, byte[] msg, byte[] sig)
    {
        try
        {
            if (pub.Length != 32 || sig.Length != 64) return false;
            var mask = BigInteger.Pow(2, 255) - 1;
            var ay = LE(pub) & mask; var asign = (pub[31] >> 7) & 1;
            if (ay >= P) return false;                      // reject non-canonical y (y >= p)
            var ax = RecoverX(ay, asign); if (ax == null) return false;
            var a = new[] { ax.Value, ay, BigInteger.One, Mod(ax.Value * ay) };
            if (Mod(MulPoint(8, a)[0]) == 0) return false;  // reject small-order public keys (8*A is the identity -> any message would verify)
            var ry = LE(sig[0..32]) & mask; var rsign = (sig[31] >> 7) & 1;
            var rx = RecoverX(ry, rsign); if (rx == null) return false;
            var r = new[] { rx.Value, ry, BigInteger.One, Mod(rx.Value * ry) };
            var s = LE(sig[32..64]); if (s >= L) return false;
            var buf = new byte[64 + msg.Length];
            Array.Copy(sig, 0, buf, 0, 32); Array.Copy(pub, 0, buf, 32, 32);
            if (msg.Length > 0) Array.Copy(msg, 0, buf, 64, msg.Length);
            var k = LE(SHA512.HashData(buf)) % L;
            var lhs = MulPoint(s, B);
            var rhs = AddPoints(r, MulPoint(k, a));
            return Mod(lhs[0] * rhs[2]) == Mod(rhs[0] * lhs[2])
                && Mod(lhs[1] * rhs[2]) == Mod(rhs[1] * lhs[2]);
        }
        catch { return false; }
    }
}

// Verify a minisign signature over message bytes. pubB64 = the key line of a .pub file;
// sigB64 = the base64 (2nd) line of a .minisig. Legacy 'Ed' (non-prehashed) only.
// shortcut: prehashed 'ED' (BLAKE2b) unsupported; sign manifests with minisign's legacy mode.
public static class Minisign
{
    public static (bool ok, string why, string keyid) Verify(string pubB64, string sigB64, byte[] message)
    {
        try
        {
            var pk = Convert.FromBase64String(pubB64.Trim());
            var sg = Convert.FromBase64String(sigB64.Trim());
            if (pk.Length != 42 || sg.Length != 74) return (false, "bad key/sig length", "");
            var salg = Encoding.ASCII.GetString(sg, 0, 2);
            var palg = Encoding.ASCII.GetString(pk, 0, 2);
            if (salg != "Ed" || palg != "Ed") return (false, "unsupported algorithm (need legacy Ed)", "");
            for (int i = 0; i < 8; i++) if (pk[2 + i] != sg[2 + i]) return (false, "key id mismatch", "");
            var ok = Ed25519.Verify(pk[10..42], message, sg[10..74]);
            return (ok, ok ? "verified" : "signature does not match", Convert.ToHexString(pk[2..10]));
        }
        catch (Exception ex) { return (false, ex.Message, ""); }
    }
}
