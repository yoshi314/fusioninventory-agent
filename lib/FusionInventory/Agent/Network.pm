package FusionInventory::Agent::Network;

use strict;
use warnings;

use English qw(-no_match_vars);
use HTTP::Status;
use UNIVERSAL::require;
use URI;


use FusionInventory::Compress;

sub new {
    my ($class, $params) = @_;

    my $self = {
        defaultTimeout => 180
    };

    $self->{accountinfo} = $params->{accountinfo}; # Q: Is that needed?

    my $config = $self->{config} = $params->{config};
    my $logger = $self->{logger} = $params->{logger};
    my $target = $self->{target} = $params->{target};

    $logger->fault('$target not initialised') unless $target;
    $logger->fault('$config not initialised') unless $config;

    $self->{compress} = FusionInventory::Compress->new({logger => $logger});

    eval {
        require LWP::UserAgent;
    };
    if ($EVAL_ERROR) {
        $logger->fault("Can't load LWP::UserAgent. Is the package installed?");
    }
    eval {
        require HTTP::Status;
    };
    if ($EVAL_ERROR) {
        $logger->fault("Can't load HTTP::Status. Is the package installed?");
    }

    $self->{URI} = $target->{path};

    bless $self, $class;
    return $self;
}

sub createUA {
    my ($self, $args) = @_;

    my $noProxy = $args->{noProxy};
    my $timeout = $args->{timeout};
    my $forceRealm = $args->{forceRealm};

    my $config = $self->{config};
    my $logger = $self->{logger};
    
    my $uri      = URI->new($args->{URI});
    my $host     = $uri->host();
    my $protocol = $uri->scheme();
    my $port     = $uri->port();

   if (!$port) {
       $port = $protocol eq 'https' ? 443 : 80;
   }

    $logger->fault("Unsupported protocol $protocol")
        unless $protocol eq 'http' or $protocol eq 'https';

    my $ua = LWP::UserAgent->new(keep_alive => 1);

    if ($noProxy) {

        # Not thread safe :(
        foreach (qw/HTTP_PROXY HTTPS_PROXY/) {
            next unless $ENV{$_};
            $self->{ProxySaved}{$_} = $ENV{$_};
            $ENV{$_} = undef;
        }

    } else {

        foreach (qw/HTTP_PROXY HTTPS_PROXY/) {
            next unless $self->{ProxySaved}{$_};
            $ENV{$_} = $self->{ProxySaved}{$_};
            undef $self->{ProxySaved}{$_};
        }

    }


    if ($self->{config}->{proxy}) {

        if ($protocol eq 'http') {
            $ENV{HTTP_PROXY} = $self->{config}->{proxy};
            $ua->env_proxy;
        } elsif ($protocol eq 'https') {
            $ENV{HTTPS_PROXY} = $self->{config}->{proxy};
            # Crypt::SSLeay do the proxy connexion itself with
            # $ENV{HTTPS_PROXY}.
        }

    }

    # Connect to server
    my $version = 'FusionInventory-Agent_v'.$config->{VERSION};
    $ua->agent($version);
    $ua->timeout($timeout);

    $self->setSslRemoteHost({
            ua => $ua,
            url => $uri
        });

    # Auth
    my $realm = $forceRealm || $self->{config}->{realm};
    $ua->credentials(
        "$host:$port",
        $realm,
        $self->{config}->{user},
        $self->{config}->{password}
    );

    return $ua;
}

sub send {
    my ($self, $args) = @_;

    my $logger = $self->{logger};
    my $target = $self->{target};
    my $config = $self->{config};

    my $compress = $self->{compress};
    my $message = $args->{message};
    my ($msgtype) = ref($message) =~ /::(\w+)$/; # Inventory or Prolog


    my $req = HTTP::Request->new(POST => $self->{URI});

    $req->header(
        'Pragma'       => 'no-cache',
        'Content-type' => 'application/x-compress'
    );

    $logger->debug ("sending XML");

    # Print the XMLs in the debug output
    #$logger->debug ("sending: ".$message->getContent());

    my $compressed = $compress->compress( $message->getContent() );

    if (!$compressed) {
        $logger->error ('failed to compress data');
        return;
    }

    $req->content($compressed);

    my $ua = $self->createUA({URI => $self->{URI}});
    my $res;
    eval {
        if ($^O =~ /^MSWin/ && $self->{URI} =~ /^https:/g) {
            alarm $self->{defaultTimeout};
        }
        $res = $ua->request($req);
        alarm 0;
    };


    my $serverRealm;
    if ($res->code == '401' && $res->header('www-authenticate') =~ /^Basic realm="(.*)"/ && !$self->{config}->{realm}) {
        $serverRealm = $1;
        $logger->debug("Basic HTTP Auth: fixing the realm to '$serverRealm' and retrying.");

        $ua = $self->createUA({URI => $self->{URI}, forceRealm => $serverRealm});
        eval {
            if ($^O =~ /^MSWin/ && $self->{URI} =~ /^https:/g) {
                alarm $self->{defaultTimeout};
            }
            $res = $ua->request($req);
            alarm 0;
        }
    }

    # Checking if connected
    if(!$res->is_success) {
        $logger->error ('Cannot establish communication with `'.
            $self->{URI}.': '.
            $res->status_line.'`');
        return;
    }

    # Ok we found the correct realm. We store it.
    $self->{config}->{realm} = $serverRealm if $serverRealm;

    # stop or send in the http's body

    my $content = '';

    if ($res->content) {
        $content = $compress->uncompress($res->content);
        if (!$content) {
            $logger->error ("Deflating problem. Is the string really ".
            "compressed? Do you use the correct URL to the server. ".
            "The begin was: ".substr($res->content, 0, 200));

            return;
        }
    }

    # AutoLoad the proper response object
    my $msgType = ref($message); # The package name of the message object
    my $tmp = "FusionInventory::Agent::XML::Response::".$msgtype;
    $tmp->require();
    if ($EVAL_ERROR) {
        $logger->error("Can't load response module $tmp: $EVAL_ERROR");
    }
    $tmp->import();
    my $response = $tmp->new({
        accountinfo => $target->{accountinfo},
        content => $content,
        logger => $logger,
        origmsg => $message,
        target => $target,
        config => $self->{config}
    });

    return $response;
}

# No POD documentation here, it's an internal fuction
# http://stackoverflow.com/questions/74358/validate-server-certificate-with-lwp
sub turnSSLCheckOn {
    my ($self, $args) = @_;

    my $logger = $self->{logger};
    my $config = $self->{config};


    if ($config->{'no-ssl-check'}) {
        if (!$config->{SslCheckWarningShown}) {
            $logger->info( "--no-ssl-check parameter "
                . "found. Don't check server identity!!!" );
            $config->{SslCheckWarningShown} = 1;
        }
        return;
    }

    if (!$config->{'ca-cert-file'} && !$config->{'ca-cert-dir'}) {
        $logger->debug("You may need to use either --ca-cert-file ".
            "or --ca-cert-dir to give the location of your SSL ".
            "certificat. You can also disable SSL check with ".
            "--no-ssl-check but this is very unsecure.");
    }


    if ($config->{'ca-cert-file'}) {
        if (!-f $config->{'ca-cert-file'} && !-l $config->{'ca-cert-file'}) {
            $logger->fault("--ca-cert-file doesn't existe ".
                "`".$config->{'ca-cert-file'}."'");
        }

        $ENV{HTTPS_CA_FILE} = $config->{'ca-cert-file'};

    } elsif ($config->{'ca-cert-dir'}) {
        if (!-d $config->{'ca-cert-dir'}) {
            $logger->fault("--ca-cert-dir doesn't existe ".
                "`".$config->{'ca-cert-dir'}."'");
        }

        $ENV{HTTPS_CA_DIR} =$config->{'ca-cert-dir'};

    }

}

sub setSslRemoteHost {
    my ($self, $args) = @_;

    my $config = $self->{config};
    my $logger = $self->{logger};

    my $uri = $args->{URI};
    my $ua = $args->{ua};

    if ($config->{'no-ssl-check'}) {
        return;
    }

    if (!$self->{URI}) {
        $logger->fault("setSslRemoteHost(), no url parameter!");
    }

    if ($self->{URI} !~ /^https:/i) {
        return;
    }
    $self->turnSSLCheckOn();

    # Check server name against provided SSL certificate
    if ( $self->{URI} =~ /^https:\/\/([^\/]+).*$/i ) {
        my $re = $1;
        # Accept SSL cert will hostname with wild-card
        # http://forge.fusioninventory.org/issues/542
        $re =~ s/^([^\.]+)/($1|\\*)/;
        # protect some characters, $re will be evaluated as a regex
        $re =~ s/([\-\.])/\\$1/g;
        $ua->default_header('If-SSL-Cert-Subject' => '/CN='.$re.'($|\/)');
    }
}


sub getStore {
    my ($self, $args) = @_;

    my $source = $args->{source};
    my $target = $args->{target};
    my $timeout = $args->{timeout};
    my $noProxy = $args->{noProxy};

    my $ua = $self->createUA({
            URI => $source,
            timeout => $timeout,
            noProxy => $noProxy,
        });

    $ua->timeout($timeout) if $timeout;

    my $response;
    eval {
        if ($^O =~ /^MSWin/ && $source =~ /^https:/g) {
            alarm $self->{defaultTimeout};
        }

        my $request = HTTP::Request->new(GET => $source);
        $response = $ua->request($request, $target);
        alarm 0;
    };

    return $response->code;

}

sub get {
    my ($self, $args) = @_;

    my $source = $args->{source};
    my $timeout = $args->{timeout};
    my $noProxy = $args->{noProxy};

    my $ua = $self->createUA({
            URI => $source,
            timeout => $timeout,
            noProxy => $noProxy,
        });

    my $response = $ua->get($source);

    return $response->decoded_content if $response->is_success;

    return;
}


sub isSuccess {
    my ($self, $args) = @_;

    my $code = $args->{code};

    return is_success($code);

}

1;
__END__

=head1 NAME

FusionInventory::Agent::Network - the Network abstraction layer

=head1 DESCRIPTION

This module is the abstraction layer for network interaction. It uses LWP.

=head1 METHODS

=head2 new()

The constructor. These keys are expected: config, logger, target.

        my $network = FusionInventory::Agent::Network->new ({

                logger => $logger,
                config => $config,
                target => $target,

            });

=head2 send()

Send an instance of FusionInventory::Agent::XML::Query::* to the target (the
server).

=head2 getStore()

Acts like LWP::Simple::getstore.

        my $rc = $network->getStore({
                source => 'http://www.FusionInventory.org/',
                target => '/tmp/fusioinventory.html'
                noProxy => 0
            });

$rc, can be read by isSuccess()

=head2 get()

        my $content = $network->get({
                source => 'http://www.FusionInventory.org/',
                timeout => 15,
                noProxy => 0
            });

Act like LWP::Simple::get, return the HTTP content of the URL in 'source'.
The timeout is optional

=head2 isSuccess()

Wrapper for LWP::is_success;

        die unless $network->isSuccess({ code => $rc });
