class Rsync < Formula
  desc "Utility that provides fast incremental file transfer"
  homepage "https://rsync.samba.org/"
  url "https://download.samba.org/pub/rsync/rsync-3.3.0.tar.gz"
  mirror "https://www.mirrorservice.org/sites/rsync.samba.org/rsync-3.3.0.tar.gz"
  sha256 "7399e9a6708c32d678a72a63219e96f23be0be2336e50fd1348498d07041df90"
  license "GPL-3.0-or-later"

  bottle do
    sha256 "2ef6e346128dc48da775e366aa6c1167206587012f2c3f8d37701b2afd3487be" => :tiger_altivec
  end

  depends_on "lz4"
  depends_on "openssl3"
  depends_on "popt"
  depends_on "xxhash"
  depends_on "zlib"

  def install
    ENV.append_to_cflags "-DSUPPORT_FILEFLAGS"
    args = %W[
      --prefix=#{prefix}
      --with-rsyncd-conf=#{etc}/rsyncd.conf
      --with-included-popt=no
      --with-included-zlib=no
      --enable-ipv6
      --disable-zstd
    ]

    system "./configure", *args
    system "make"
    system "make", "install"
  end

  test do
    mkdir "a"
    mkdir "b"

    ["foo\n", "bar\n", "baz\n"].map.with_index do |s, i|
      (testpath/"a/#{i + 1}.txt").write s
    end

    system bin/"rsync", "-artv", testpath/"a/", testpath/"b/"

    (1..3).each do |i|
      assert_equal (testpath/"a/#{i}.txt").read, (testpath/"b/#{i}.txt").read
    end
  end

  # Carry patches/fileflags.diff from rsync-patches archive
  # Diff touched m4 file requiring autoconfing again needlessly.
  # https://download.samba.org/pub/rsync/src/rsync-patches-3.2.7.tar.gz
  patch :DATA
end
__END__
diff --git a/compat.c b/compat.c
--- a/compat.c
+++ b/compat.c
@@ -40,6 +40,7 @@ extern int checksum_seed;
 extern int basis_dir_cnt;
 extern int prune_empty_dirs;
 extern int protocol_version;
+extern int force_change;
 extern int protect_args;
 extern int preserve_uid;
 extern int preserve_gid;
@@ -47,6 +48,7 @@ extern int preserve_atimes;
 extern int preserve_crtimes;
 extern int preserve_acls;
 extern int preserve_xattrs;
+extern int preserve_fileflags;
 extern int xfer_flags_as_varint;
 extern int need_messages_from_generator;
 extern int delete_mode, delete_before, delete_during, delete_after;
@@ -86,7 +88,7 @@ struct name_num_item *xattr_sum_nni;
 int xattr_sum_len = 0;
 
 /* These index values are for the file-list's extra-attribute array. */
-int pathname_ndx, depth_ndx, atimes_ndx, crtimes_ndx, uid_ndx, gid_ndx, acls_ndx, xattrs_ndx, unsort_ndx;
+int pathname_ndx, depth_ndx, atimes_ndx, crtimes_ndx, uid_ndx, gid_ndx, fileflags_ndx, acls_ndx, xattrs_ndx, unsort_ndx;
 
 int receiver_symlink_times = 0; /* receiver can set the time on a symlink */
 int sender_symlink_iconv = 0;	/* sender should convert symlink content */
@@ -588,6 +590,8 @@ void setup_protocol(int f_out,int f_in)
 		uid_ndx = ++file_extra_cnt;
 	if (preserve_gid)
 		gid_ndx = ++file_extra_cnt;
+	if (preserve_fileflags || (force_change && !am_sender))
+		fileflags_ndx = ++file_extra_cnt;
 	if (preserve_acls && !am_sender)
 		acls_ndx = ++file_extra_cnt;
 	if (preserve_xattrs)
@@ -751,6 +755,10 @@ void setup_protocol(int f_out,int f_in)
 			fprintf(stderr, "Both rsync versions must be at least 3.2.0 for --crtimes.\n");
 			exit_cleanup(RERR_PROTOCOL);
 		}
+		if (!xfer_flags_as_varint && preserve_fileflags) {
+			fprintf(stderr, "Both rsync versions must be at least 3.2.0 for --fileflags.\n");
+			exit_cleanup(RERR_PROTOCOL);
+		}
 		if (am_sender) {
 			receiver_symlink_times = am_server
 			    ? strchr(client_info, 'L') != NULL
diff --git a/delete.c b/delete.c
--- a/delete.c
+++ b/delete.c
@@ -25,6 +25,7 @@
 extern int am_root;
 extern int make_backups;
 extern int max_delete;
+extern int force_change;
 extern char *backup_dir;
 extern char *backup_suffix;
 extern int backup_suffix_len;
@@ -97,8 +98,12 @@ static enum delret delete_dir_contents(char *fname, uint16 flags)
 		}
 
 		strlcpy(p, fp->basename, remainder);
+#ifdef SUPPORT_FORCE_CHANGE
+		if (force_change)
+			make_mutable(fname, fp->mode, F_FFLAGS(fp), force_change);
+#endif
 		if (!(fp->mode & S_IWUSR) && !am_root && fp->flags & FLAG_OWNED_BY_US)
-			do_chmod(fname, fp->mode | S_IWUSR);
+			do_chmod(fname, fp->mode | S_IWUSR, NO_FFLAGS);
 		/* Save stack by recursing to ourself directly. */
 		if (S_ISDIR(fp->mode)) {
 			if (delete_dir_contents(fname, flags | DEL_RECURSE) != DR_SUCCESS)
@@ -139,11 +144,18 @@ enum delret delete_item(char *fbuf, uint16 mode, uint16 flags)
 	}
 
 	if (flags & DEL_NO_UID_WRITE)
-		do_chmod(fbuf, mode | S_IWUSR);
+		do_chmod(fbuf, mode | S_IWUSR, NO_FFLAGS);
 
 	if (S_ISDIR(mode) && !(flags & DEL_DIR_IS_EMPTY)) {
 		/* This only happens on the first call to delete_item() since
 		 * delete_dir_contents() always calls us w/DEL_DIR_IS_EMPTY. */
+#ifdef SUPPORT_FORCE_CHANGE
+		if (force_change) {
+			STRUCT_STAT st;
+			if (x_lstat(fbuf, &st, NULL) == 0)
+				make_mutable(fbuf, st.st_mode, st.st_flags, force_change);
+		}
+#endif
 		ignore_perishable = 1;
 		/* If DEL_RECURSE is not set, this just reports emptiness. */
 		ret = delete_dir_contents(fbuf, flags);
diff --git a/flist.c b/flist.c
--- a/flist.c
+++ b/flist.c
@@ -52,6 +52,7 @@ extern int preserve_links;
 extern int preserve_hard_links;
 extern int preserve_devices;
 extern int preserve_specials;
+extern int preserve_fileflags;
 extern int delete_during;
 extern int missing_args;
 extern int eol_nulls;
@@ -388,6 +389,9 @@ static void send_file_entry(int f, const char *fname, struct file_struct *file,
 	static time_t crtime;
 #endif
 	static mode_t mode;
+#ifdef SUPPORT_FILEFLAGS
+	static uint32 fileflags;
+#endif
 #ifdef SUPPORT_HARD_LINKS
 	static int64 dev;
 #endif
@@ -431,6 +435,14 @@ static void send_file_entry(int f, const char *fname, struct file_struct *file,
 		xflags |= XMIT_SAME_MODE;
 	else
 		mode = file->mode;
+#ifdef SUPPORT_FILEFLAGS
+	if (preserve_fileflags) {
+		if (F_FFLAGS(file) == fileflags)
+			xflags |= XMIT_SAME_FLAGS;
+		else
+			fileflags = F_FFLAGS(file);
+	}
+#endif
 
 	if (preserve_devices && IS_DEVICE(mode)) {
 		if (protocol_version < 28) {
@@ -592,6 +604,10 @@ static void send_file_entry(int f, const char *fname, struct file_struct *file,
 #endif
 	if (!(xflags & XMIT_SAME_MODE))
 		write_int(f, to_wire_mode(mode));
+#ifdef SUPPORT_FILEFLAGS
+	if (preserve_fileflags && !(xflags & XMIT_SAME_FLAGS))
+		write_int(f, (int)fileflags);
+#endif
 	if (atimes_ndx && !S_ISDIR(mode) && !(xflags & XMIT_SAME_ATIME))
 		write_varlong(f, atime, 4);
 	if (preserve_uid && !(xflags & XMIT_SAME_UID)) {
@@ -686,6 +702,9 @@ static struct file_struct *recv_file_entry(int f, struct file_list *flist, int x
 	static time_t crtime;
 #endif
 	static mode_t mode;
+#ifdef SUPPORT_FILEFLAGS
+	static uint32 fileflags;
+#endif
 #ifdef SUPPORT_HARD_LINKS
 	static int64 dev;
 #endif
@@ -803,6 +822,10 @@ static struct file_struct *recv_file_entry(int f, struct file_list *flist, int x
 #ifdef SUPPORT_CRTIMES
 			if (crtimes_ndx)
 				crtime = F_CRTIME(first);
+#endif
+#ifdef SUPPORT_FILEFLAGS
+			if (preserve_fileflags)
+				fileflags = F_FFLAGS(first);
 #endif
 			if (preserve_uid)
 				uid = F_OWNER(first);
@@ -876,6 +899,10 @@ static struct file_struct *recv_file_entry(int f, struct file_list *flist, int x
 
 	if (chmod_modes && !S_ISLNK(mode) && mode)
 		mode = tweak_mode(mode, chmod_modes);
+#ifdef SUPPORT_FILEFLAGS
+	if (preserve_fileflags && !(xflags & XMIT_SAME_FLAGS))
+		fileflags = (uint32)read_int(f);
+#endif
 
 	if (preserve_uid && !(xflags & XMIT_SAME_UID)) {
 		if (protocol_version < 30)
@@ -1057,6 +1084,10 @@ static struct file_struct *recv_file_entry(int f, struct file_list *flist, int x
 	}
 #endif
 	file->mode = mode;
+#ifdef SUPPORT_FILEFLAGS
+	if (preserve_fileflags)
+		F_FFLAGS(file) = fileflags;
+#endif
 	if (preserve_uid)
 		F_OWNER(file) = uid;
 	if (preserve_gid) {
@@ -1470,6 +1501,10 @@ struct file_struct *make_file(const char *fname, struct file_list *flist,
 	}
 #endif
 	file->mode = st.st_mode;
+#if defined SUPPORT_FILEFLAGS || defined SUPPORT_FORCE_CHANGE
+	if (fileflags_ndx)
+		F_FFLAGS(file) = st.st_flags;
+#endif
 	if (preserve_uid)
 		F_OWNER(file) = st.st_uid;
 	if (preserve_gid)
diff --git a/generator.c b/generator.c
--- a/generator.c
+++ b/generator.c
@@ -43,10 +43,12 @@ extern int preserve_devices;
 extern int preserve_specials;
 extern int preserve_hard_links;
 extern int preserve_executability;
+extern int preserve_fileflags;
 extern int preserve_perms;
 extern int preserve_mtimes;
 extern int omit_dir_times;
 extern int omit_link_times;
+extern int force_change;
 extern int delete_mode;
 extern int delete_before;
 extern int delete_during;
@@ -486,6 +488,10 @@ int unchanged_attrs(const char *fname, struct file_struct *file, stat_x *sxp)
 			return 0;
 		if (perms_differ(file, sxp))
 			return 0;
+#ifdef SUPPORT_FILEFLAGS
+		if (preserve_fileflags && sxp->st.st_flags != F_FFLAGS(file))
+			return 0;
+#endif
 		if (ownership_differs(file, sxp))
 			return 0;
 #ifdef SUPPORT_ACLS
@@ -547,6 +553,11 @@ void itemize(const char *fnamecmp, struct file_struct *file, int ndx, int statre
 			iflags |= ITEM_REPORT_OWNER;
 		if (gid_ndx && !(file->flags & FLAG_SKIP_GROUP) && sxp->st.st_gid != (gid_t)F_GROUP(file))
 			iflags |= ITEM_REPORT_GROUP;
+#ifdef SUPPORT_FILEFLAGS
+		if (preserve_fileflags && !S_ISLNK(file->mode)
+		 && sxp->st.st_flags != F_FFLAGS(file))
+			iflags |= ITEM_REPORT_FFLAGS;
+#endif
 #ifdef SUPPORT_ACLS
 		if (preserve_acls && !S_ISLNK(file->mode)) {
 			if (!ACL_READY(*sxp))
@@ -1454,6 +1465,10 @@ static void recv_generator(char *fname, struct file_struct *file, int ndx,
 		if (!preserve_perms) { /* See comment in non-dir code below. */
 			file->mode = dest_mode(file->mode, sx.st.st_mode, dflt_perms, statret == 0);
 		}
+#ifdef SUPPORT_FORCE_CHANGE
+		if (force_change && !preserve_fileflags)
+			F_FFLAGS(file) = sx.st.st_flags;
+#endif
 		if (statret != 0 && basis_dir[0] != NULL) {
 			int j = try_dests_non(file, fname, ndx, fnamecmpbuf, &sx, itemizing, code);
 			if (j == -2) {
@@ -1496,10 +1511,15 @@ static void recv_generator(char *fname, struct file_struct *file, int ndx,
 		 * readable and writable permissions during the time we are
 		 * putting files within them.  This is then restored to the
 		 * former permissions after the transfer is done. */
+#ifdef SUPPORT_FORCE_CHANGE
+		if (force_change && F_FFLAGS(file) & force_change
+		 && make_mutable(fname, file->mode, F_FFLAGS(file), force_change))
+			need_retouch_dir_perms = 1;
+#endif
 #ifdef HAVE_CHMOD
 		if (!am_root && (file->mode & S_IRWXU) != S_IRWXU && dir_tweaking) {
 			mode_t mode = file->mode | S_IRWXU;
-			if (do_chmod(fname, mode) < 0) {
+			if (do_chmod(fname, mode, 0) < 0) {
 				rsyserr(FERROR_XFER, errno,
 					"failed to modify permissions on %s",
 					full_fname(fname));
@@ -1534,6 +1554,10 @@ static void recv_generator(char *fname, struct file_struct *file, int ndx,
 		int exists = statret == 0 && stype != FT_DIR;
 		file->mode = dest_mode(file->mode, sx.st.st_mode, dflt_perms, exists);
 	}
+#ifdef SUPPORT_FORCE_CHANGE
+	if (force_change && !preserve_fileflags)
+		F_FFLAGS(file) = sx.st.st_flags;
+#endif
 
 #ifdef SUPPORT_HARD_LINKS
 	if (preserve_hard_links && F_HLINK_NOT_FIRST(file)
@@ -2107,17 +2131,25 @@ static void touch_up_dirs(struct file_list *flist, int ndx)
 			continue;
 		fname = f_name(file, NULL);
 		if (fix_dir_perms)
-			do_chmod(fname, file->mode);
+			do_chmod(fname, file->mode, 0);
 		if (need_retouch_dir_times) {
 			STRUCT_STAT st;
 			if (link_stat(fname, &st, 0) == 0 && mtime_differs(&st, file)) {
 				st.st_mtime = file->modtime;
 #ifdef ST_MTIME_NSEC
 				st.ST_MTIME_NSEC = F_MOD_NSEC_or_0(file);
+#endif
+#ifdef SUPPORT_FORCE_CHANGE
+				st.st_mode = file->mode;
+				st.st_flags = 0;
 #endif
 				set_times(fname, &st);
 			}
 		}
+#ifdef SUPPORT_FORCE_CHANGE
+		if (force_change && F_FFLAGS(file) & force_change)
+			undo_make_mutable(fname, F_FFLAGS(file));
+#endif
 		if (counter >= loopchk_limit) {
 			if (allowed_lull)
 				maybe_send_keepalive(time(NULL), MSK_ALLOW_FLUSH);
diff --git a/log.c b/log.c
--- a/log.c
+++ b/log.c
@@ -725,7 +725,8 @@ static void log_formatted(enum logcode code, const char *format, const char *op,
 			     : iflags & ITEM_REPORT_ATIME ? 'u' : 'n';
 			c[9] = !(iflags & ITEM_REPORT_ACL) ? '.' : 'a';
 			c[10] = !(iflags & ITEM_REPORT_XATTR) ? '.' : 'x';
-			c[11] = '\0';
+			c[11] = !(iflags & ITEM_REPORT_FFLAGS) ? '.' : 'f';
+			c[12] = '\0';
 
 			if (iflags & (ITEM_IS_NEW|ITEM_MISSING_DATA)) {
 				char ch = iflags & ITEM_IS_NEW ? '+' : '?';
diff --git a/main.c b/main.c
--- a/main.c
+++ b/main.c
@@ -31,6 +31,9 @@
 #ifdef __TANDEM
 #include <floss.h(floss_execlp)>
 #endif
+#ifdef SUPPORT_FORCE_CHANGE
+#include <sys/sysctl.h>
+#endif
 
 extern int dry_run;
 extern int list_only;
@@ -49,6 +52,7 @@ extern int need_messages_from_generator;
 extern int kluge_around_eof;
 extern int got_xfer_error;
 extern int old_style_args;
+extern int force_change;
 extern int msgs2stderr;
 extern int module_id;
 extern int read_only;
@@ -975,6 +979,22 @@ static int do_recv(int f_in, int f_out, char *local_name)
 	 * points to an identical file won't be replaced by the referent. */
 	copy_links = copy_dirlinks = copy_unsafe_links = 0;
 
+#ifdef SUPPORT_FORCE_CHANGE
+	if (force_change & SYS_IMMUTABLE) {
+		/* Determine whether we'll be able to unlock a system immutable item. */
+		int mib[2];
+		int securityLevel = 0;
+		size_t len = sizeof securityLevel;
+
+		mib[0] = CTL_KERN;
+		mib[1] = KERN_SECURELVL;
+		if (sysctl(mib, 2, &securityLevel, &len, NULL, 0) == 0 && securityLevel > 0) {
+			rprintf(FERROR, "System security level is too high to force mutability on system immutable files and directories.\n");
+			exit_cleanup(RERR_UNSUPPORTED);
+		}
+	}
+#endif
+
 #ifdef SUPPORT_HARD_LINKS
 	if (preserve_hard_links && !inc_recurse)
 		match_hard_links(first_flist);
diff --git a/options.c b/options.c
--- a/options.c
+++ b/options.c
@@ -56,6 +56,7 @@ int preserve_hard_links = 0;
 int preserve_acls = 0;
 int preserve_xattrs = 0;
 int preserve_perms = 0;
+int preserve_fileflags = 0;
 int preserve_executability = 0;
 int preserve_devices = 0;
 int preserve_specials = 0;
@@ -98,6 +99,7 @@ int msgs2stderr = 2; /* Default: send errors to stderr for local & remote-shell
 int saw_stderr_opt = 0;
 int allow_8bit_chars = 0;
 int force_delete = 0;
+int force_change = 0;
 int io_timeout = 0;
 int prune_empty_dirs = 0;
 int use_qsort = 0;
@@ -622,6 +624,8 @@ static struct poptOption long_options[] = {
   {"perms",           'p', POPT_ARG_VAL,    &preserve_perms, 1, 0, 0 },
   {"no-perms",         0,  POPT_ARG_VAL,    &preserve_perms, 0, 0, 0 },
   {"no-p",             0,  POPT_ARG_VAL,    &preserve_perms, 0, 0, 0 },
+  {"fileflags",        0,  POPT_ARG_VAL,    &preserve_fileflags, 1, 0, 0 },
+  {"no-fileflags",     0,  POPT_ARG_VAL,    &preserve_fileflags, 0, 0, 0 },
   {"executability",   'E', POPT_ARG_NONE,   &preserve_executability, 0, 0, 0 },
   {"acls",            'A', POPT_ARG_NONE,   0, 'A', 0, 0 },
   {"no-acls",          0,  POPT_ARG_VAL,    &preserve_acls, 0, 0, 0 },
@@ -720,6 +724,12 @@ static struct poptOption long_options[] = {
   {"remove-source-files",0,POPT_ARG_VAL,    &remove_source_files, 1, 0, 0 },
   {"force",            0,  POPT_ARG_VAL,    &force_delete, 1, 0, 0 },
   {"no-force",         0,  POPT_ARG_VAL,    &force_delete, 0, 0, 0 },
+  {"force-delete",     0,  POPT_ARG_VAL,    &force_delete, 1, 0, 0 },
+  {"no-force-delete",  0,  POPT_ARG_VAL,    &force_delete, 0, 0, 0 },
+  {"force-change",     0,  POPT_ARG_VAL,    &force_change, ALL_IMMUTABLE, 0, 0 },
+  {"no-force-change",  0,  POPT_ARG_VAL,    &force_change, 0, 0, 0 },
+  {"force-uchange",    0,  POPT_ARG_VAL,    &force_change, USR_IMMUTABLE, 0, 0 },
+  {"force-schange",    0,  POPT_ARG_VAL,    &force_change, SYS_IMMUTABLE, 0, 0 },
   {"ignore-errors",    0,  POPT_ARG_VAL,    &ignore_errors, 1, 0, 0 },
   {"no-ignore-errors", 0,  POPT_ARG_VAL,    &ignore_errors, 0, 0, 0 },
   {"max-delete",       0,  POPT_ARG_INT,    &max_delete, 0, 0, 0 },
@@ -1015,6 +1025,14 @@ static void set_refuse_options(void)
 #ifndef SUPPORT_CRTIMES
 	parse_one_refuse_match(0, "crtimes", list_end);
 #endif
+#ifndef SUPPORT_FILEFLAGS
+	parse_one_refuse_match(0, "fileflags", list_end);
+#endif
+#ifndef SUPPORT_FORCE_CHANGE
+	parse_one_refuse_match(0, "force-change", list_end);
+	parse_one_refuse_match(0, "force-uchange", list_end);
+	parse_one_refuse_match(0, "force-schange", list_end);
+#endif
 
 	/* Now we use the descrip values to actually mark the options for refusal. */
 	for (op = long_options; op != list_end; op++) {
@@ -2712,6 +2730,9 @@ void server_options(char **args, int *argc_p)
 	if (xfer_dirs && !recurse && delete_mode && am_sender)
 		args[ac++] = "--no-r";
 
+	if (preserve_fileflags)
+		args[ac++] = "--fileflags";
+
 	if (do_compression && do_compression_level != CLVL_NOT_SPECIFIED) {
 		if (asprintf(&arg, "--compress-level=%d", do_compression_level) < 0)
 			goto oom;
@@ -2807,6 +2828,16 @@ void server_options(char **args, int *argc_p)
 			args[ac++] = "--delete-excluded";
 		if (force_delete)
 			args[ac++] = "--force";
+#ifdef SUPPORT_FORCE_CHANGE
+		if (force_change) {
+			if (force_change == ALL_IMMUTABLE)
+				args[ac++] = "--force-change";
+			else if (force_change == USR_IMMUTABLE)
+				args[ac++] = "--force-uchange";
+			else if (force_change == SYS_IMMUTABLE)
+				args[ac++] = "--force-schange";
+		}
+#endif
 		if (write_batch < 0)
 			args[ac++] = "--only-write-batch=X";
 		if (am_root > 1)
diff --git a/rsync.1.md b/rsync.1.md
--- a/rsync.1.md
+++ b/rsync.1.md
@@ -446,6 +446,7 @@ has its own detailed description later in this manpage.
 --keep-dirlinks, -K      treat symlinked dir on receiver as dir
 --hard-links, -H         preserve hard links
 --perms, -p              preserve permissions
+--fileflags              preserve file-flags (aka chflags)
 --executability, -E      preserve executability
 --chmod=CHMOD            affect file and/or directory permissions
 --acls, -A               preserve ACLs (implies --perms)
@@ -487,7 +488,10 @@ has its own detailed description later in this manpage.
 --ignore-missing-args    ignore missing source args without error
 --delete-missing-args    delete missing source args from destination
 --ignore-errors          delete even if there are I/O errors
---force                  force deletion of dirs even if not empty
+--force-delete           force deletion of directories even if not empty
+--force-change           affect user-/system-immutable files/dirs
+--force-uchange          affect user-immutable files/dirs
+--force-schange          affect system-immutable files/dirs
 --max-delete=NUM         don't delete more than NUM files
 --max-size=SIZE          don't transfer any file larger than SIZE
 --min-size=SIZE          don't transfer any file smaller than SIZE
@@ -831,6 +835,7 @@ expand it.
     recursion and want to preserve almost everything.  Be aware that it does
     **not** include preserving ACLs (`-A`), xattrs (`-X`), atimes (`-U`),
     crtimes (`-N`), nor the finding and preserving of hardlinks (`-H`).
+    It also does **not** imply [`--fileflags`](#opt).
 
     The only exception to the above equivalence is when [`--files-from`](#opt)
     is specified, in which case [`-r`](#opt) is not implied.
@@ -1295,7 +1300,7 @@ expand it.
     Without this option, if the sending side has replaced a directory with a
     symlink to a directory, the receiving side will delete anything that is in
     the way of the new symlink, including a directory hierarchy (as long as
-    [`--force`](#opt) or [`--delete`](#opt) is in effect).
+    [`--force-delete`](#opt) or [`--delete`](#opt) is in effect).
 
     See also [`--keep-dirlinks`](#opt) for an analogous option for the
     receiving side.
@@ -1490,6 +1495,37 @@ expand it.
     those used by [`--fake-super`](#opt)) unless you repeat the option (e.g. `-XX`).
     This "copy all xattrs" mode cannot be used with [`--fake-super`](#opt).
 
+0.  `--fileflags`
+
+    This option causes rsync to update the file-flags to be the same as the
+    source files and directories (if your OS supports the **chflags**(2) system
+    call).   Some flags can only be altered by the super-user and some might
+    only be unset below a certain secure-level (usually single-user mode). It
+    will not make files alterable that are set to immutable on the receiver.
+    To do that, see [`--force-change`](#opt), [`--force-uchange`](#opt), and
+    [`--force-schange`](#opt).
+
+0.  `--force-change`
+
+    This option causes rsync to disable both user-immutable and
+    system-immutable flags on files and directories that are being updated or
+    deleted on the receiving side.  This option overrides
+    [`--force-uchange`](#opt) and [`--force-schange`](#opt).
+
+0.  `--force-uchange`
+
+    This option causes rsync to disable user-immutable flags on files and
+    directories that are being updated or deleted on the receiving side.  It
+    does not try to affect system flags.  This option overrides
+    [`--force-change`](#opt) and [`--force-schange`](#opt).
+
+0.  `--force-schange`
+
+    This option causes rsync to disable system-immutable flags on files and
+    directories that are being updated or deleted on the receiving side.  It
+    does not try to affect user flags.  This option overrides
+    [`--force-change`](#opt) and [`--force-uchange`](#opt).
+
 0.  `--chmod=CHMOD`
 
     This option tells rsync to apply one or more comma-separated "chmod" modes
@@ -2017,8 +2053,8 @@ expand it.
     [`--ignore-missing-args`](#opt) option a step farther: each missing arg
     will become a deletion request of the corresponding destination file on the
     receiving side (should it exist).  If the destination file is a non-empty
-    directory, it will only be successfully deleted if [`--force`](#opt) or
-    [`--delete`](#opt) are in effect.  Other than that, this option is
+    directory, it will only be successfully deleted if [`--force-delete`](#opt)
+    or [`--delete`](#opt) are in effect.  Other than that, this option is
     independent of any other type of delete processing.
 
     The missing source files are represented by special file-list entries which
@@ -2029,14 +2065,14 @@ expand it.
     Tells [`--delete`](#opt) to go ahead and delete files even when there are
     I/O errors.
 
-0.  `--force`
+0.  `--force-delete`, `--force`
 
     This option tells rsync to delete a non-empty directory when it is to be
     replaced by a non-directory.  This is only relevant if deletions are not
     active (see [`--delete`](#opt) for details).
 
-    Note for older rsync versions: `--force` used to still be required when
-    using [`--delete-after`](#opt), and it used to be non-functional unless the
+    Note that some older rsync versions used to require `--force` when using
+    [`--delete-after`](#opt), and it used to be non-functional unless the
     [`--recursive`](#opt) option was also enabled.
 
 0.  `--max-delete=NUM`
@@ -3096,7 +3132,7 @@ expand it.
     also turns on the output of other verbose messages).
 
     The "%i" escape has a cryptic output that is 11 letters long.  The general
-    format is like the string `YXcstpoguax`, where **Y** is replaced by the type
+    format is like the string `YXcstpoguaxf`, where **Y** is replaced by the type
     of update being done, **X** is replaced by the file-type, and the other
     letters represent attributes that may be output if they are being modified.
 
diff --git a/rsync.c b/rsync.c
--- a/rsync.c
+++ b/rsync.c
@@ -31,6 +31,7 @@ extern int dry_run;
 extern int preserve_acls;
 extern int preserve_xattrs;
 extern int preserve_perms;
+extern int preserve_fileflags;
 extern int preserve_executability;
 extern int preserve_mtimes;
 extern int omit_dir_times;
@@ -468,6 +469,39 @@ mode_t dest_mode(mode_t flist_mode, mode_t stat_mode, int dflt_perms,
 	return new_mode;
 }
 
+#if defined SUPPORT_FILEFLAGS || defined SUPPORT_FORCE_CHANGE
+/* Set a file's st_flags. */
+static int set_fileflags(const char *fname, uint32 fileflags)
+{
+	if (do_chflags(fname, fileflags) != 0) {
+		rsyserr(FERROR_XFER, errno,
+			"failed to set file flags on %s",
+			full_fname(fname));
+		return 0;
+	}
+
+	return 1;
+}
+
+/* Remove immutable flags from an object, so it can be altered/removed. */
+int make_mutable(const char *fname, mode_t mode, uint32 fileflags, uint32 iflags)
+{
+	if (S_ISLNK(mode) || !(fileflags & iflags))
+		return 0;
+	if (!set_fileflags(fname, fileflags & ~iflags))
+		return -1;
+	return 1;
+}
+
+/* Undo a prior make_mutable() call that returned a 1. */
+int undo_make_mutable(const char *fname, uint32 fileflags)
+{
+	if (!set_fileflags(fname, fileflags))
+		return -1;
+	return 1;
+}
+#endif
+
 static int same_mtime(struct file_struct *file, STRUCT_STAT *st, int extra_accuracy)
 {
 #ifdef ST_MTIME_NSEC
@@ -544,7 +578,7 @@ int set_file_attrs(const char *fname, struct file_struct *file, stat_x *sxp,
 		if (am_root >= 0) {
 			uid_t uid = change_uid ? (uid_t)F_OWNER(file) : sxp->st.st_uid;
 			gid_t gid = change_gid ? (gid_t)F_GROUP(file) : sxp->st.st_gid;
-			if (do_lchown(fname, uid, gid) != 0) {
+			if (do_lchown(fname, uid, gid, sxp->st.st_mode, ST_FLAGS(sxp->st)) != 0) {
 				/* We shouldn't have attempted to change uid
 				 * or gid unless have the privilege. */
 				rsyserr(FERROR_XFER, errno, "%s %s failed",
@@ -654,7 +688,7 @@ int set_file_attrs(const char *fname, struct file_struct *file, stat_x *sxp,
 
 #ifdef HAVE_CHMOD
 	if (!BITS_EQUAL(sxp->st.st_mode, new_mode, CHMOD_BITS)) {
-		int ret = am_root < 0 ? 0 : do_chmod(fname, new_mode);
+		int ret = am_root < 0 ? 0 : do_chmod(fname, new_mode, ST_FLAGS(sxp->st));
 		if (ret < 0) {
 			rsyserr(FERROR_XFER, errno,
 				"failed to set permissions on %s",
@@ -666,6 +700,19 @@ int set_file_attrs(const char *fname, struct file_struct *file, stat_x *sxp,
 	}
 #endif
 
+#ifdef SUPPORT_FILEFLAGS
+	if (preserve_fileflags && !S_ISLNK(sxp->st.st_mode)
+	 && sxp->st.st_flags != F_FFLAGS(file)) {
+		uint32 fileflags = F_FFLAGS(file);
+		if (flags & ATTRS_DELAY_IMMUTABLE)
+			fileflags &= ~ALL_IMMUTABLE;
+		if (sxp->st.st_flags != fileflags
+		 && !set_fileflags(fname, fileflags))
+			goto cleanup;
+		updated = 1;
+	}
+#endif
+
 	if (INFO_GTE(NAME, 2) && flags & ATTRS_REPORT) {
 		if (updated)
 			rprintf(FCLIENT, "%s\n", fname);
@@ -743,7 +790,8 @@ int finish_transfer(const char *fname, const char *fnametmp,
 
 	/* Change permissions before putting the file into place. */
 	set_file_attrs(fnametmp, file, NULL, fnamecmp,
-		       ok_to_set_time ? ATTRS_ACCURATE_TIME : ATTRS_SKIP_MTIME | ATTRS_SKIP_ATIME | ATTRS_SKIP_CRTIME);
+		       ATTRS_DELAY_IMMUTABLE
+		       | (ok_to_set_time ? ATTRS_ACCURATE_TIME : ATTRS_SKIP_MTIME | ATTRS_SKIP_ATIME | ATTRS_SKIP_CRTIME));
 
 	/* move tmp file over real file */
 	if (DEBUG_GTE(RECV, 1))
@@ -760,6 +808,10 @@ int finish_transfer(const char *fname, const char *fnametmp,
 	}
 	if (ret == 0) {
 		/* The file was moved into place (not copied), so it's done. */
+#ifdef SUPPORT_FILEFLAGS
+		if (preserve_fileflags && F_FFLAGS(file) & ALL_IMMUTABLE)
+			set_fileflags(fname, F_FFLAGS(file));
+#endif
 		return 1;
 	}
 	/* The file was copied, so tweak the perms of the copied file.  If it
diff --git a/rsync.h b/rsync.h
--- a/rsync.h
+++ b/rsync.h
@@ -69,7 +69,7 @@
 
 /* The following XMIT flags require an rsync that uses a varint for the flag values */
 
-#define XMIT_RESERVED_16 (1<<16) 	/* reserved for future fileflags use */
+#define XMIT_SAME_FLAGS (1<<16) 	/* any protocol - restricted by command-line option */
 #define XMIT_CRTIME_EQ_MTIME (1<<17)	/* any protocol - restricted by command-line option */
 
 /* These flags are used in the live flist data. */
@@ -192,6 +192,7 @@
 #define ATTRS_SKIP_MTIME	(1<<1)
 #define ATTRS_ACCURATE_TIME	(1<<2)
 #define ATTRS_SKIP_ATIME	(1<<3)
+#define ATTRS_DELAY_IMMUTABLE	(1<<4)
 #define ATTRS_SKIP_CRTIME	(1<<5)
 
 #define MSG_FLUSH	2
@@ -220,6 +221,7 @@
 #define ITEM_REPORT_GROUP (1<<6)
 #define ITEM_REPORT_ACL (1<<7)
 #define ITEM_REPORT_XATTR (1<<8)
+#define ITEM_REPORT_FFLAGS (1<<9)
 #define ITEM_REPORT_CRTIME (1<<10)
 #define ITEM_BASIS_TYPE_FOLLOWS (1<<11)
 #define ITEM_XNAME_FOLLOWS (1<<12)
@@ -587,6 +589,31 @@ typedef unsigned int size_t;
 #define SUPPORT_CRTIMES 1
 #endif
 
+#define NO_FFLAGS ((uint32)-1)
+
+#ifdef HAVE_CHFLAGS
+#define SUPPORT_FILEFLAGS 1
+#define SUPPORT_FORCE_CHANGE 1
+#endif
+
+#if defined SUPPORT_FILEFLAGS || defined SUPPORT_FORCE_CHANGE
+#ifndef UF_NOUNLINK
+#define UF_NOUNLINK 0
+#endif
+#ifndef SF_NOUNLINK
+#define SF_NOUNLINK 0
+#endif
+#define USR_IMMUTABLE (UF_IMMUTABLE|UF_NOUNLINK|UF_APPEND)
+#define SYS_IMMUTABLE (SF_IMMUTABLE|SF_NOUNLINK|SF_APPEND)
+#define ALL_IMMUTABLE (USR_IMMUTABLE|SYS_IMMUTABLE)
+#define ST_FLAGS(st) ((st).st_flags)
+#else
+#define USR_IMMUTABLE 0
+#define SYS_IMMUTABLE 0
+#define ALL_IMMUTABLE 0
+#define ST_FLAGS(st) NO_FFLAGS
+#endif
+
 /* Find a variable that is either exactly 32-bits or longer.
  * If some code depends on 32-bit truncation, it will need to
  * take special action in a "#if SIZEOF_INT32 > 4" section. */
@@ -818,6 +845,7 @@ extern int pathname_ndx;
 extern int depth_ndx;
 extern int uid_ndx;
 extern int gid_ndx;
+extern int fileflags_ndx;
 extern int acls_ndx;
 extern int xattrs_ndx;
 extern int file_sum_extra_cnt;
@@ -873,6 +901,11 @@ extern int file_sum_extra_cnt;
 /* When the associated option is on, all entries will have these present: */
 #define F_OWNER(f) REQ_EXTRA(f, uid_ndx)->unum
 #define F_GROUP(f) REQ_EXTRA(f, gid_ndx)->unum
+#if defined SUPPORT_FILEFLAGS || defined SUPPORT_FORCE_CHANGE
+#define F_FFLAGS(f) REQ_EXTRA(f, fileflags_ndx)->unum
+#else
+#define F_FFLAGS(f) NO_FFLAGS
+#endif
 #define F_ACL(f) REQ_EXTRA(f, acls_ndx)->num
 #define F_XATTR(f) REQ_EXTRA(f, xattrs_ndx)->num
 #define F_NDX(f) REQ_EXTRA(f, unsort_ndx)->num
diff --git a/syscall.c b/syscall.c
--- a/syscall.c
+++ b/syscall.c
@@ -38,6 +38,7 @@ extern int am_root;
 extern int am_sender;
 extern int read_only;
 extern int list_only;
+extern int force_change;
 extern int inplace;
 extern int preallocate_files;
 extern int preserve_perms;
@@ -81,7 +82,23 @@ int do_unlink(const char *path)
 {
 	if (dry_run) return 0;
 	RETURN_ERROR_IF_RO_OR_LO;
-	return unlink(path);
+	if (unlink(path) == 0)
+		return 0;
+#ifdef SUPPORT_FORCE_CHANGE
+	if (force_change && errno == EPERM) {
+		STRUCT_STAT st;
+
+		if (x_lstat(path, &st, NULL) == 0
+		 && make_mutable(path, st.st_mode, st.st_flags, force_change) > 0) {
+			if (unlink(path) == 0)
+				return 0;
+			undo_make_mutable(path, st.st_flags);
+		}
+		/* TODO: handle immutable directories */
+		errno = EPERM;
+	}
+#endif
+	return -1;
 }
 
 #ifdef SUPPORT_LINKS
@@ -146,14 +163,35 @@ int do_link(const char *old_path, const char *new_path)
 }
 #endif
 
-int do_lchown(const char *path, uid_t owner, gid_t group)
+int do_lchown(const char *path, uid_t owner, gid_t group, UNUSED(mode_t mode), UNUSED(uint32 fileflags))
 {
 	if (dry_run) return 0;
 	RETURN_ERROR_IF_RO_OR_LO;
 #ifndef HAVE_LCHOWN
 #define lchown chown
 #endif
-	return lchown(path, owner, group);
+	if (lchown(path, owner, group) == 0)
+		return 0;
+#ifdef SUPPORT_FORCE_CHANGE
+	if (force_change && errno == EPERM) {
+		if (fileflags == NO_FFLAGS) {
+			STRUCT_STAT st;
+			if (x_lstat(path, &st, NULL) == 0) {
+				mode = st.st_mode;
+				fileflags = st.st_flags;
+			}
+		}
+		if (fileflags != NO_FFLAGS
+		 && make_mutable(path, mode, fileflags, force_change) > 0) {
+			int ret = lchown(path, owner, group);
+			undo_make_mutable(path, fileflags);
+			if (ret == 0)
+				return 0;
+		}
+		errno = EPERM;
+	}
+#endif
+	return -1;
 }
 
 int do_mknod(const char *pathname, mode_t mode, dev_t dev)
@@ -193,7 +231,7 @@ int do_mknod(const char *pathname, mode_t mode, dev_t dev)
 			return -1;
 		close(sock);
 #ifdef HAVE_CHMOD
-		return do_chmod(pathname, mode);
+		return do_chmod(pathname, mode, 0);
 #else
 		return 0;
 #endif
@@ -210,7 +248,22 @@ int do_rmdir(const char *pathname)
 {
 	if (dry_run) return 0;
 	RETURN_ERROR_IF_RO_OR_LO;
-	return rmdir(pathname);
+	if (rmdir(pathname) == 0)
+		return 0;
+#ifdef SUPPORT_FORCE_CHANGE
+	if (force_change && errno == EPERM) {
+		STRUCT_STAT st;
+
+		if (x_lstat(pathname, &st, NULL) == 0
+		 && make_mutable(pathname, st.st_mode, st.st_flags, force_change) > 0) {
+			if (rmdir(pathname) == 0)
+				return 0;
+			undo_make_mutable(pathname, st.st_flags);
+		}
+		errno = EPERM;
+	}
+#endif
+	return -1;
 }
 
 int do_open(const char *pathname, int flags, mode_t mode)
@@ -229,7 +282,7 @@ int do_open(const char *pathname, int flags, mode_t mode)
 }
 
 #ifdef HAVE_CHMOD
-int do_chmod(const char *path, mode_t mode)
+int do_chmod(const char *path, mode_t mode, UNUSED(uint32 fileflags))
 {
 	static int switch_step = 0;
 	int code;
@@ -268,17 +321,72 @@ int do_chmod(const char *path, mode_t mode)
 			code = chmod(path, mode & CHMOD_BITS); /* DISCOURAGED FUNCTION */
 		break;
 	}
+#ifdef SUPPORT_FORCE_CHANGE
+	if (code < 0 && force_change && errno == EPERM && !S_ISLNK(mode)) {
+		if (fileflags == NO_FFLAGS) {
+			STRUCT_STAT st;
+			if (x_lstat(path, &st, NULL) == 0)
+				fileflags = st.st_flags;
+		}
+		if (fileflags != NO_FFLAGS
+		 && make_mutable(path, mode, fileflags, force_change) > 0) {
+			code = chmod(path, mode & CHMOD_BITS);
+			undo_make_mutable(path, fileflags);
+			if (code == 0)
+				return 0;
+		}
+		errno = EPERM;
+	}
+#endif
 	if (code != 0 && (preserve_perms || preserve_executability))
 		return code;
 	return 0;
 }
 #endif
 
+#ifdef HAVE_CHFLAGS
+int do_chflags(const char *path, uint32 fileflags)
+{
+	if (dry_run) return 0;
+	RETURN_ERROR_IF_RO_OR_LO;
+	return chflags(path, fileflags);
+}
+#endif
+
 int do_rename(const char *old_path, const char *new_path)
 {
 	if (dry_run) return 0;
 	RETURN_ERROR_IF_RO_OR_LO;
-	return rename(old_path, new_path);
+	if (rename(old_path, new_path) == 0)
+		return 0;
+#ifdef SUPPORT_FORCE_CHANGE
+	if (force_change && errno == EPERM) {
+		STRUCT_STAT st1, st2;
+		int became_mutable;
+
+		if (x_lstat(old_path, &st1, NULL) != 0)
+			goto failed;
+		became_mutable = make_mutable(old_path, st1.st_mode, st1.st_flags, force_change) > 0;
+		if (became_mutable && rename(old_path, new_path) == 0)
+			goto success;
+		if (x_lstat(new_path, &st2, NULL) == 0
+		 && make_mutable(new_path, st2.st_mode, st2.st_flags, force_change) > 0) {
+			if (rename(old_path, new_path) == 0) {
+			  success:
+				if (became_mutable) /* Yes, use new_path and st1! */
+					undo_make_mutable(new_path, st1.st_flags);
+				return 0;
+			}
+			undo_make_mutable(new_path, st2.st_flags);
+		}
+		/* TODO: handle immutable directories */
+		if (became_mutable)
+			undo_make_mutable(old_path, st1.st_flags);
+	  failed:
+		errno = EPERM;
+	}
+#endif
+	return -1;
 }
 
 #ifdef HAVE_FTRUNCATE
diff --git a/t_stub.c b/t_stub.c
--- a/t_stub.c
+++ b/t_stub.c
@@ -29,6 +29,8 @@ int protect_args = 0;
 int module_id = -1;
 int relative_paths = 0;
 int module_dirlen = 0;
+int force_change = 0;
+int preserve_acls = 0;
 int preserve_xattrs = 0;
 int preserve_perms = 0;
 int preserve_executability = 0;
@@ -111,3 +113,23 @@ filter_rule_list daemon_filter_list;
 {
 	return cst ? 0 : 0;
 }
+
+#if defined SUPPORT_FILEFLAGS || defined SUPPORT_FORCE_CHANGE
+ int make_mutable(UNUSED(const char *fname), UNUSED(mode_t mode), UNUSED(uint32 fileflags), UNUSED(uint32 iflags))
+{
+	return 0;
+}
+
+/* Undo a prior make_mutable() call that returned a 1. */
+ int undo_make_mutable(UNUSED(const char *fname), UNUSED(uint32 fileflags))
+{
+	return 0;
+}
+#endif
+
+#ifdef SUPPORT_XATTRS
+ int x_lstat(UNUSED(const char *fname), UNUSED(STRUCT_STAT *fst), UNUSED(STRUCT_STAT *xst))
+{
+	return -1;
+}
+#endif
diff --git a/testsuite/rsync.fns b/testsuite/rsync.fns
--- a/testsuite/rsync.fns
+++ b/testsuite/rsync.fns
@@ -26,9 +26,9 @@ chkfile="$scratchdir/rsync.chk"
 outfile="$scratchdir/rsync.out"
 
 # For itemized output:
-all_plus='+++++++++'
-allspace='         '
-dots='.....' # trailing dots after changes
+all_plus='++++++++++'
+allspace='          '
+dots='......' # trailing dots after changes
 tab_ch='	' # a single tab character
 
 # Berkley's nice.
diff --git a/usage.c b/usage.c
--- a/usage.c
+++ b/usage.c
@@ -138,6 +138,11 @@ static void print_info_flags(enum logcode f)
 #endif
 			"crtimes",
 
+#ifndef SUPPORT_FILEFLAGS
+		"no "
+#endif
+			"file-flags",
+
 	"*Optimizations",
 
 #ifndef USE_ROLL_SIMD
diff --git a/util1.c b/util1.c
--- a/util1.c
+++ b/util1.c
@@ -34,6 +34,7 @@ extern int relative_paths;
 extern int preserve_xattrs;
 extern int omit_link_times;
 extern int preallocate_files;
+extern int force_change;
 extern char *module_dir;
 extern unsigned int module_dirlen;
 extern char *partial_dir;
@@ -116,6 +117,33 @@ void print_child_argv(const char *prefix, char **cmd)
 	rprintf(FCLIENT, " (%d args)\n", cnt);
 }
 
+#ifdef SUPPORT_FORCE_CHANGE
+static int try_a_force_change(const char *fname, STRUCT_STAT *stp)
+{
+	uint32 fileflags = ST_FLAGS(*stp);
+	if (fileflags == NO_FFLAGS) {
+		STRUCT_STAT st;
+		if (x_lstat(fname, &st, NULL) == 0)
+			fileflags = st.st_flags;
+	}
+	if (fileflags != NO_FFLAGS && make_mutable(fname, stp->st_mode, fileflags, force_change) > 0) {
+		int ret, save_force_change = force_change;
+
+		force_change = 0; /* Make certain we can't come back here. */
+		ret = set_times(fname, stp);
+		force_change = save_force_change;
+
+		undo_make_mutable(fname, fileflags);
+
+		return ret;
+	}
+
+	errno = EPERM;
+
+	return -1;
+}
+#endif
+
 /* This returns 0 for success, 1 for a symlink if symlink time-setting
  * is not possible, or -1 for any other error. */
 int set_times(const char *fname, STRUCT_STAT *stp)
@@ -143,6 +171,10 @@ int set_times(const char *fname, STRUCT_STAT *stp)
 #include "case_N.h"
 		if (do_utimensat(fname, stp) == 0)
 			break;
+#ifdef SUPPORT_FORCE_CHANGE
+		if (force_change && errno == EPERM && try_a_force_change(fname, stp) == 0)
+			break;
+#endif
 		if (errno != ENOSYS)
 			return -1;
 		switch_step++;
@@ -152,6 +184,10 @@ int set_times(const char *fname, STRUCT_STAT *stp)
 #include "case_N.h"
 		if (do_lutimes(fname, stp) == 0)
 			break;
+#ifdef SUPPORT_FORCE_CHANGE
+		if (force_change && errno == EPERM && try_a_force_change(fname, stp) == 0)
+			break;
+#endif
 		if (errno != ENOSYS)
 			return -1;
 		switch_step++;
@@ -173,6 +209,10 @@ int set_times(const char *fname, STRUCT_STAT *stp)
 		if (do_utime(fname, stp) == 0)
 			break;
 #endif
+#ifdef SUPPORT_FORCE_CHANGE
+		if (force_change && errno == EPERM && try_a_force_change(fname, stp) == 0)
+			break;
+#endif
 
 		return -1;
 	}
diff --git a/xattrs.c b/xattrs.c
--- a/xattrs.c
+++ b/xattrs.c
@@ -1086,7 +1086,7 @@ int set_xattr(const char *fname, const struct file_struct *file, const char *fna
 	 && !S_ISLNK(sxp->st.st_mode)
 #endif
 	 && access(fname, W_OK) < 0
-	 && do_chmod(fname, (sxp->st.st_mode & CHMOD_BITS) | S_IWUSR) == 0)
+	 && do_chmod(fname, (sxp->st.st_mode & CHMOD_BITS) | S_IWUSR, ST_FLAGS(sxp->st)) == 0)
 		added_write_perm = 1;
 
 	ndx = F_XATTR(file);
@@ -1094,7 +1094,7 @@ int set_xattr(const char *fname, const struct file_struct *file, const char *fna
 	lst = &glst->xa_items;
 	int return_value = rsync_xal_set(fname, lst, fnamecmp, sxp);
 	if (added_write_perm) /* remove the temporary write permission */
-		do_chmod(fname, sxp->st.st_mode);
+		do_chmod(fname, sxp->st.st_mode, ST_FLAGS(sxp->st));
 	return return_value;
 }
 
@@ -1211,7 +1211,7 @@ int set_stat_xattr(const char *fname, struct file_struct *file, mode_t new_mode)
 	mode = (fst.st_mode & _S_IFMT) | (fmode & ACCESSPERMS)
 	     | (S_ISDIR(fst.st_mode) ? 0700 : 0600);
 	if (fst.st_mode != mode)
-		do_chmod(fname, mode);
+		do_chmod(fname, mode, ST_FLAGS(fst));
 	if (!IS_DEVICE(fst.st_mode))
 		fst.st_rdev = 0; /* just in case */
 
diff -Nurp a/rsync.1 b/rsync.1
--- a/rsync.1
+++ b/rsync.1
@@ -543,6 +543,7 @@ has its own detailed description later i
 --keep-dirlinks, -K      treat symlinked dir on receiver as dir
 --hard-links, -H         preserve hard links
 --perms, -p              preserve permissions
+--fileflags              preserve file-flags (aka chflags)
 --executability, -E      preserve executability
 --chmod=CHMOD            affect file and/or directory permissions
 --acls, -A               preserve ACLs (implies --perms)
@@ -584,7 +585,10 @@ has its own detailed description later i
 --ignore-missing-args    ignore missing source args without error
 --delete-missing-args    delete missing source args from destination
 --ignore-errors          delete even if there are I/O errors
---force                  force deletion of dirs even if not empty
+--force-delete           force deletion of directories even if not empty
+--force-change           affect user-/system-immutable files/dirs
+--force-uchange          affect user-immutable files/dirs
+--force-schange          affect system-immutable files/dirs
 --max-delete=NUM         don't delete more than NUM files
 --max-size=SIZE          don't transfer any file larger than SIZE
 --min-size=SIZE          don't transfer any file smaller than SIZE
@@ -915,6 +919,7 @@ This is equivalent to \fB\-rlptgoD\fP.
 recursion and want to preserve almost everything.  Be aware that it does
 \fBnot\fP include preserving ACLs (\fB\-A\fP), xattrs (\fB\-X\fP), atimes (\fB\-U\fP),
 crtimes (\fB\-N\fP), nor the finding and preserving of hardlinks (\fB\-H\fP).
+It also does \fBnot\fP imply \fB\-\-fileflags\fP.
 .IP
 The only exception to the above equivalence is when \fB\-\-files-from\fP
 is specified, in which case \fB\-r\fP is not implied.
@@ -1379,7 +1384,7 @@ to non-directories to be affected, as th
 Without this option, if the sending side has replaced a directory with a
 symlink to a directory, the receiving side will delete anything that is in
 the way of the new symlink, including a directory hierarchy (as long as
-\fB\-\-force\fP or \fB\-\-delete\fP is in effect).
+\fB\-\-force-delete\fP or \fB\-\-delete\fP is in effect).
 .IP
 See also \fB\-\-keep-dirlinks\fP for an analogous option for the
 receiving side.
@@ -1597,6 +1602,29 @@ receiver-only rule that excludes all nam
 Note that the \fB\-X\fP option does not copy rsync's special xattr values (e.g.
 those used by \fB\-\-fake-super\fP) unless you repeat the option (e.g. \fB\-XX\fP).
 This "copy all xattrs" mode cannot be used with \fB\-\-fake-super\fP.
+.IP "\fB\-\-fileflags\fP"
+This option causes rsync to update the file-flags to be the same as the
+source files and directories (if your OS supports the \fBchflags\fP(2) system
+call).   Some flags can only be altered by the super-user and some might
+only be unset below a certain secure-level (usually single-user mode). It
+will not make files alterable that are set to immutable on the receiver.
+To do that, see \fB\-\-force-change\fP, \fB\-\-force-uchange\fP, and
+\fB\-\-force-schange\fP.
+.IP "\fB\-\-force-change\fP"
+This option causes rsync to disable both user-immutable and
+system-immutable flags on files and directories that are being updated or
+deleted on the receiving side.  This option overrides
+\fB\-\-force-uchange\fP and \fB\-\-force-schange\fP.
+.IP "\fB\-\-force-uchange\fP"
+This option causes rsync to disable user-immutable flags on files and
+directories that are being updated or deleted on the receiving side.  It
+does not try to affect system flags.  This option overrides
+\fB\-\-force-change\fP and \fB\-\-force-schange\fP.
+.IP "\fB\-\-force-schange\fP"
+This option causes rsync to disable system-immutable flags on files and
+directories that are being updated or deleted on the receiving side.  It
+does not try to affect user flags.  This option overrides
+\fB\-\-force-change\fP and \fB\-\-force-uchange\fP.
 .IP "\fB\-\-chmod=CHMOD\fP"
 This option tells rsync to apply one or more comma-separated "chmod" modes
 to the permission of the files in the transfer.  The resulting value is
@@ -2078,8 +2106,8 @@ This option takes the behavior of the (i
 \fB\-\-ignore-missing-args\fP option a step farther: each missing arg
 will become a deletion request of the corresponding destination file on the
 receiving side (should it exist).  If the destination file is a non-empty
-directory, it will only be successfully deleted if \fB\-\-force\fP or
-\fB\-\-delete\fP are in effect.  Other than that, this option is
+directory, it will only be successfully deleted if \fB\-\-force-delete\fP
+or \fB\-\-delete\fP are in effect.  Other than that, this option is
 independent of any other type of delete processing.
 .IP
 The missing source files are represented by special file-list entries which
@@ -2087,13 +2115,13 @@ display as a "\fB*missing\fP" entry in t
 .IP "\fB\-\-ignore-errors\fP"
 Tells \fB\-\-delete\fP to go ahead and delete files even when there are
 I/O errors.
-.IP "\fB\-\-force\fP"
+.IP "\fB\-\-force-delete\fP, \fB\-\-force\fP"
 This option tells rsync to delete a non-empty directory when it is to be
 replaced by a non-directory.  This is only relevant if deletions are not
 active (see \fB\-\-delete\fP for details).
 .IP
-Note for older rsync versions: \fB\-\-force\fP used to still be required when
-using \fB\-\-delete-after\fP, and it used to be non-functional unless the
+Note that some older rsync versions used to require \fB\-\-force\fP when using
+\fB\-\-delete-after\fP, and it used to be non-functional unless the
 \fB\-\-recursive\fP option was also enabled.
 .IP "\fB\-\-max-delete=NUM\fP"
 This tells rsync not to delete more than NUM files or directories.  If that
@@ -3154,7 +3182,7 @@ version 2.6.7 (you can use \fB\-vv\fP wi
 also turns on the output of other verbose messages).
 .IP
 The "%i" escape has a cryptic output that is 11 letters long.  The general
-format is like the string \fBYXcstpoguax\fP, where \fBY\fP is replaced by the type
+format is like the string \fBYXcstpoguaxf\fP, where \fBY\fP is replaced by the type
 of update being done, \fBX\fP is replaced by the file-type, and the other
 letters represent attributes that may be output if they are being modified.
 .IP
diff -Nurp a/rsync.1.html b/rsync.1.html
--- a/rsync.1.html
+++ b/rsync.1.html
@@ -438,6 +438,7 @@ has its own detailed description later i
 --keep-dirlinks, -K      treat symlinked dir on receiver as dir
 --hard-links, -H         preserve hard links
 --perms, -p              preserve permissions
+--fileflags              preserve file-flags (aka chflags)
 --executability, -E      preserve executability
 --chmod=CHMOD            affect file and/or directory permissions
 --acls, -A               preserve ACLs (implies --perms)
@@ -479,7 +480,10 @@ has its own detailed description later i
 --ignore-missing-args    ignore missing source args without error
 --delete-missing-args    delete missing source args from destination
 --ignore-errors          delete even if there are I/O errors
---force                  force deletion of dirs even if not empty
+--force-delete           force deletion of directories even if not empty
+--force-change           affect user-/system-immutable files/dirs
+--force-uchange          affect user-immutable files/dirs
+--force-schange          affect system-immutable files/dirs
 --max-delete=NUM         don't delete more than NUM files
 --max-size=SIZE          don't transfer any file larger than SIZE
 --min-size=SIZE          don't transfer any file smaller than SIZE
@@ -806,7 +810,8 @@ section.</p>
 <p>This is equivalent to <code>-rlptgoD</code>.  It is a quick way of saying you want
 recursion and want to preserve almost everything.  Be aware that it does
 <strong>not</strong> include preserving ACLs (<code>-A</code>), xattrs (<code>-X</code>), atimes (<code>-U</code>),
-crtimes (<code>-N</code>), nor the finding and preserving of hardlinks (<code>-H</code>).</p>
+crtimes (<code>-N</code>), nor the finding and preserving of hardlinks (<code>-H</code>).
+It also does <strong>not</strong> imply <a href="#opt--fileflags"><code>--fileflags</code></a>.</p>
 <p>The only exception to the above equivalence is when <a href="#opt--files-from"><code>--files-from</code></a>
 is specified, in which case <a href="#opt-r"><code>-r</code></a> is not implied.</p>
 </dd>
@@ -1234,7 +1239,7 @@ to non-directories to be affected, as th
 <p>Without this option, if the sending side has replaced a directory with a
 symlink to a directory, the receiving side will delete anything that is in
 the way of the new symlink, including a directory hierarchy (as long as
-<a href="#opt--force"><code>--force</code></a> or <a href="#opt--delete"><code>--delete</code></a> is in effect).</p>
+<a href="#opt--force-delete"><code>--force-delete</code></a> or <a href="#opt--delete"><code>--delete</code></a> is in effect).</p>
 <p>See also <a href="#opt--keep-dirlinks"><code>--keep-dirlinks</code></a> for an analogous option for the
 receiving side.</p>
 <p><code>--copy-dirlinks</code> applies to all symlinks to directories in the source.  If
@@ -1421,6 +1426,37 @@ those used by <a href="#opt--fake-super"
 This &quot;copy all xattrs&quot; mode cannot be used with <a href="#opt--fake-super"><code>--fake-super</code></a>.</p>
 </dd>
 
+<dt id="opt--fileflags"><code>--fileflags</code><a href="#opt--fileflags" class="tgt"></a></dt><dd>
+<p>This option causes rsync to update the file-flags to be the same as the
+source files and directories (if your OS supports the <strong>chflags</strong>(2) system
+call).   Some flags can only be altered by the super-user and some might
+only be unset below a certain secure-level (usually single-user mode). It
+will not make files alterable that are set to immutable on the receiver.
+To do that, see <a href="#opt--force-change"><code>--force-change</code></a>, <a href="#opt--force-uchange"><code>--force-uchange</code></a>, and
+<a href="#opt--force-schange"><code>--force-schange</code></a>.</p>
+</dd>
+
+<dt id="opt--force-change"><code>--force-change</code><a href="#opt--force-change" class="tgt"></a></dt><dd>
+<p>This option causes rsync to disable both user-immutable and
+system-immutable flags on files and directories that are being updated or
+deleted on the receiving side.  This option overrides
+<a href="#opt--force-uchange"><code>--force-uchange</code></a> and <a href="#opt--force-schange"><code>--force-schange</code></a>.</p>
+</dd>
+
+<dt id="opt--force-uchange"><code>--force-uchange</code><a href="#opt--force-uchange" class="tgt"></a></dt><dd>
+<p>This option causes rsync to disable user-immutable flags on files and
+directories that are being updated or deleted on the receiving side.  It
+does not try to affect system flags.  This option overrides
+<a href="#opt--force-change"><code>--force-change</code></a> and <a href="#opt--force-schange"><code>--force-schange</code></a>.</p>
+</dd>
+
+<dt id="opt--force-schange"><code>--force-schange</code><a href="#opt--force-schange" class="tgt"></a></dt><dd>
+<p>This option causes rsync to disable system-immutable flags on files and
+directories that are being updated or deleted on the receiving side.  It
+does not try to affect user flags.  This option overrides
+<a href="#opt--force-change"><code>--force-change</code></a> and <a href="#opt--force-uchange"><code>--force-uchange</code></a>.</p>
+</dd>
+
 <dt id="opt--chmod"><code>--chmod=CHMOD</code><a href="#opt--chmod" class="tgt"></a></dt><dd>
 <p>This option tells rsync to apply one or more comma-separated &quot;chmod&quot; modes
 to the permission of the files in the transfer.  The resulting value is
@@ -1902,8 +1938,8 @@ is no longer there.</p>
 <a href="#opt--ignore-missing-args"><code>--ignore-missing-args</code></a> option a step farther: each missing arg
 will become a deletion request of the corresponding destination file on the
 receiving side (should it exist).  If the destination file is a non-empty
-directory, it will only be successfully deleted if <a href="#opt--force"><code>--force</code></a> or
-<a href="#opt--delete"><code>--delete</code></a> are in effect.  Other than that, this option is
+directory, it will only be successfully deleted if <a href="#opt--force-delete"><code>--force-delete</code></a>
+or <a href="#opt--delete"><code>--delete</code></a> are in effect.  Other than that, this option is
 independent of any other type of delete processing.</p>
 <p>The missing source files are represented by special file-list entries which
 display as a &quot;<code>*missing</code>&quot; entry in the <a href="#opt--list-only"><code>--list-only</code></a> output.</p>
@@ -1914,12 +1950,12 @@ display as a &quot;<code>*missing</code>
 I/O errors.</p>
 </dd>
 
-<dt id="opt--force"><code>--force</code><a href="#opt--force" class="tgt"></a></dt><dd>
+<span id="opt--force"></span><dt id="opt--force-delete"><code>--force-delete</code>, <code>--force</code><a href="#opt--force-delete" class="tgt"></a></dt><dd>
 <p>This option tells rsync to delete a non-empty directory when it is to be
 replaced by a non-directory.  This is only relevant if deletions are not
 active (see <a href="#opt--delete"><code>--delete</code></a> for details).</p>
-<p>Note for older rsync versions: <code>--force</code> used to still be required when
-using <a href="#opt--delete-after"><code>--delete-after</code></a>, and it used to be non-functional unless the
+<p>Note that some older rsync versions used to require <code>--force</code> when using
+<a href="#opt--delete-after"><code>--delete-after</code></a>, and it used to be non-functional unless the
 <a href="#opt--recursive"><code>--recursive</code></a> option was also enabled.</p>
 </dd>
 
@@ -2891,7 +2927,7 @@ files will also be output, but only if t
 version 2.6.7 (you can use <code>-vv</code> with older versions of rsync, but that
 also turns on the output of other verbose messages).</p>
 <p>The &quot;%i&quot; escape has a cryptic output that is 11 letters long.  The general
-format is like the string <code>YXcstpoguax</code>, where <strong>Y</strong> is replaced by the type
+format is like the string <code>YXcstpoguaxf</code>, where <strong>Y</strong> is replaced by the type
 of update being done, <strong>X</strong> is replaced by the file-type, and the other
 letters represent attributes that may be output if they are being modified.</p>
 <p>The update types that replace the <strong>Y</strong> are as follows:</p>
