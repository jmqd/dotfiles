//! A certificate authority that lives only for one session, so the proxy can
//! read the container's GitHub traffic. Its key never leaves this process.

use anyhow::Context as _;
use rcgen::{
    BasicConstraints, CertificateParams, CertifiedIssuer, DnType, IsCa, KeyPair, KeyUsagePurpose,
};
use rustls::ServerConfig;
use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
use std::sync::Arc;

pub struct SessionCa {
    pub cert_pem: String,
    pub server_config: Arc<ServerConfig>,
}

impl SessionCa {
    pub fn new(hosts: &[&str]) -> anyhow::Result<Self> {
        let mut ca_params = CertificateParams::new(Vec::<String>::new())?;
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
        ca_params
            .distinguished_name
            .push(DnType::CommonName, "agent-box session CA");
        ca_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
        let ca = CertifiedIssuer::self_signed(ca_params, KeyPair::generate()?)?;

        let leaf_key = KeyPair::generate()?;
        let mut leaf_params = CertificateParams::new(
            hosts
                .iter()
                .map(|host| (*host).to_owned())
                .collect::<Vec<_>>(),
        )?;
        leaf_params.distinguished_name.push(
            DnType::CommonName,
            hosts.first().copied().unwrap_or("agent-box"),
        );
        let leaf = leaf_params.signed_by(&leaf_key, &ca)?;

        let mut server_config = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![leaf.der().clone(), ca.der().clone()],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key.serialize_der())),
            )
            .context("failed to build the proxy's TLS config")?;
        // The proxy speaks HTTP/1.1 to clients; advertising only that keeps
        // clients from negotiating HTTP/2.
        server_config.alpn_protocols = vec![b"http/1.1".to_vec()];

        Ok(Self {
            cert_pem: ca.pem(),
            server_config: Arc::new(server_config),
        })
    }
}
