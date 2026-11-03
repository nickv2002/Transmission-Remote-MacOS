import Foundation
import Testing

@Suite("Cloudflare Access: domains and redirects")
struct CloudflareAccessTests {
    @Test func authDomainsMustBeCloudflareAccess() {
        #expect(CloudflareAccess.authDomainHost("Team.CloudflareAccess.com") == "team.cloudflareaccess.com")
        #expect(CloudflareAccess.authDomainHost("team.cloudflareaccess.com:443") == "team.cloudflareaccess.com")
        #expect(CloudflareAccess.authDomainHost("cloudflareaccess.com.evil.example") == nil)
        #expect(CloudflareAccess.authDomainHost("evilcloudflareaccess.com") == nil)
    }

    @Test func loginRedirectsAreRecognisedByPath() {
        #expect(CloudflareAccess.isLoginRedirect(URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login/t.example.com?kid=x")))
        #expect(CloudflareAccess.isLoginRedirect(URL(string: "https://t.example.com/cdn-cgi/access/login")))
        #expect(!CloudflareAccess.isLoginRedirect(URL(string: "https://t.example.com/transmission/web/")))
        #expect(!CloudflareAccess.isLoginRedirect(nil))
    }
}
