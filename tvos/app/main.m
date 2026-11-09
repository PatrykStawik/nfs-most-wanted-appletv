// The app's entry point: everything else is in libnfsmw.a (tvos/build.sh; UIKit host in tvos/host/tv_app.m).
int nfsmw_tv_run(int argc, char **argv);
int main(int argc, char **argv) { return nfsmw_tv_run(argc, argv); }
