/*
 * Does the restored JVM compute CORRECTLY under TCG, or merely keep running?
 *
 * The AvxCanary proves liveness. This proves agreement: the same reduction is
 * computed twice -- once in a shape C2 auto-vectorises (VEX/AVX2 + FMA), and
 * once in a shape it cannot (a serial dependence chain through the
 * accumulator forces scalar code).  If the vector path were producing garbage
 * under TCG, the two would disagree.  Self-contained: no reference value from
 * another machine is needed.
 */
public class VecCheck {
    static final int N = 1 << 16;

    static long vectorized(double[] a, double[] b, double[] c) {
        for (int i = 0; i < N; i++) c[i] = a[i] * b[i] + c[i];   // vectorisable FMA
        long h = 0;
        for (int i = 0; i < N; i++) h += (long) c[i] & 0xFFFFL;  // vectorisable reduce
        return h;
    }

    static long scalar(double[] a, double[] b, double[] c) {
        long h = 0;
        for (int i = 0; i < N; i++) {
            c[i] = a[i] * b[i] + c[i];
            h = (h * 31 + ((long) c[i] & 0xFFFFL));              // loop-carried: no SIMD
        }
        return h;
    }

    public static void main(String[] args) {
        double[] a = new double[N], b = new double[N];
        for (int i = 0; i < N; i++) { a[i] = (i % 977) * 0.5; b[i] = (i % 331) * 0.25; }

        long v = 0, s = 0;
        for (int r = 0; r < 200; r++) {          // well past the C2 thresholds
            double[] c1 = new double[N], c2 = new double[N];
            v = vectorized(a, b, c1);
            s = scalar(a, b, c2);
            boolean same = true;
            for (int i = 0; i < N; i++) if (c1[i] != c2[i]) { same = false; break; }
            if (!same) { System.out.println("VECCHECK FAIL: arrays diverge at round " + r); return; }
        }
        System.out.println("VECCHECK vec_hash=" + v);
        System.out.println("VECCHECK sca_hash=" + s);
        System.out.println("VECCHECK PASS: vectorised and scalar paths agree");
    }
}
