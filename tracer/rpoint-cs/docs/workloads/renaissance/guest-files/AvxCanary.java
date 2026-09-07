/*
 * J1 canary: prove a JVM survives a KVM snapshot -> TCG restore.
 *
 * The failure this is built to detect is the AVX hflag bug (QEMU
 * cpu_post_load never re-synced HF_AVX_EN_MASK, so a KVM snapshot restored
 * under TCG ran with AVX disabled and every VEX instruction raised #UD).
 * A JVM is the worst case for that bug: HotSpot detects CPU features once at
 * startup and bakes AVX into C2-compiled code, which it CANNOT fall back from
 * the way glibc's ifuncs could.
 *
 * So this program deliberately gets C2 to vectorize a hot loop, then keeps
 * running it forever with a heartbeat.  Snapshot it mid-flight under KVM and
 * restore under TCG: if the heartbeat continues, JIT-compiled vector code
 * survived the boundary.  If the bug were still live, the JVM would die
 * immediately after restore, not gradually.
 */
public class AvxCanary {
    static final int N = 1 << 16;
    static final double[] a = new double[N], b = new double[N], c = new double[N];

    // C2 vectorizes this; on a Haswell model that means VEX-encoded AVX.
    static double kernel() {
        for (int i = 0; i < N; i++) c[i] = a[i] * b[i] + c[i];
        double s = 0;
        for (int i = 0; i < N; i++) s += c[i];
        return s;
    }

    public static void main(String[] args) throws Exception {
        for (int i = 0; i < N; i++) { a[i] = i * 0.5; b[i] = i * 0.25; }
        // force C2: run far past the compilation thresholds before we snapshot
        double warm = 0;
        for (int r = 0; r < 20000; r++) warm += kernel();
        System.out.println("CANARY warmup done, checksum=" + (long) warm);
        System.out.println("CANARY ready-for-snapshot");
        System.out.flush();

        long beat = 0;
        while (true) {
            double s = 0;
            for (int r = 0; r < 200; r++) s += kernel();
            System.out.println("CANARY beat=" + (++beat)
                             + " sum=" + (long) s
                             + " t=" + System.currentTimeMillis()
                             + " heap=" + (Runtime.getRuntime().totalMemory()
                                          - Runtime.getRuntime().freeMemory()) / (1 << 20) + "M");
            System.out.flush();
            Thread.sleep(1000);
        }
    }
}
