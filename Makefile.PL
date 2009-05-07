use inc::Module::Install;

name        "ExtUtils-PerlToExe";
all_from    "lib/ExtUtils/PerlToExe.pm";

requires    "version"               => 0;
requires    "Exporter::NoWork"      => "0.02";
requires    "List::Util"            => 0;
requires    "File::Temp"            => 0;
requires    "File::Slurp"           => "9999.09";
requires    "IPC::System::Simple"   => 0;
requires    "File::Copy"            => 0;
requires    "File::Spec"            => 0;
requires    "File::ShareDir"        => 0;
requires    "PerlIO::subfile"       => 0;
requires    "Getopt::Long"          => "2.33";
requires    "Pod::Usage"            => 0;
requires    "Data::Alias"           => 0;

install_script  "pl2exe";
install_share;

auto_install;
WriteAll;
