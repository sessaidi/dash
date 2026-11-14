// Generated from up-toolbox pkg/workspace/generate.go (the CAPIG varnish config), verbatim.
// Regenerate rather than edit by hand.

extension WorkspaceGenerator {
    /// `default.vcl` of the common-api-gateway-varnish-config ConfigMap.
    public static let varnishVCL = #"""

# specify the VCL syntax version to use
vcl 4.1;

import var;

backend default {
  .host = "127.0.0.1";
  .port = "8080";
}

sub vcl_recv {
  # handle options request without sending it to backend
  if (req.method == "OPTIONS") {
    return(pass);
  }

  if (!req.http.X-Preferred-Language) {
    set req.http.X-Preferred-Language = "en";
  }

  if (req.http.X-GCP-Country-Code == "FR") {
    var.set("country_code3", "FRA");
    var.set("country_name", "France");
    var.set("postal_code", "75007");  # Paris
  } else if (req.http.X-GCP-Country-Code == "US") {
    var.set("country_code3", "USA");
    var.set("country_name", "United States");
    var.set("postal_code", "10001");  # New York
  } else if (req.http.X-GCP-Country-Code == "CA") {
    var.set("country_code3", "CAN");
    var.set("country_name", "Canada");
    var.set("postal_code", "M5V 3A8");  # Toronto
  } else if (req.http.X-GCP-Country-Code == "ES") {
    var.set("country_code3", "ESP");
    var.set("country_name", "Spain");
    var.set("postal_code", "28001");  # Madrid
  } else {
    var.set("country_code3", "");
    var.set("country_name", "Unknown");
    var.set("postal_code", "");
  }

  if (req.url ~ "\/v3\/location") {
    set req.http.X-Fastly-Country-Name = var.get("country_name");
    set req.http.X-Fastly-Country-Code = req.http.X-GCP-Country-Code;
    set req.http.X-Fastly-Client-IP = req.http.X-GCP-Client-IP;
  }

  # --- Geolocation begin ---

  if (req.http.X-Country-Code3 || req.http.X-Postal-Code || req.http.X-Region-Code || req.http.X-Dma) {
    set req.http.X-Location-Spoofed = "true";
  }

  if (!req.http.X-Country-Code3 || req.http.X-Country-Code3 ~ "^$") {
    set req.http.X-Country-Code3 = var.get("country_code3");
    set req.http.X-Country-Code3-2 = var.get("country_code3");
  }

  if (!req.http.X-Postal-Code || req.http.X-Postal-Code ~ "^$") {
    set req.http.X-Postal-Code = var.get("postal_code");
  }

  # proxy stubs
  set req.http.X-Proxy-Type = "?";
  set req.http.X-Proxy-Description = "";

  # prevent sending these headers from client
  unset req.http.X-Ip-Allowlisted;
  unset req.http.X-Ip-Vpn-Blocklisted;

  # --- Geolocation end ---
}

# The last step before the response will be sent to the client.
sub vcl_deliver {
  set resp.http.Access-Control-Allow-Origin = req.http.Origin;

  set resp.http.Access-Control-Allow-Headers = "Accept-Encoding,Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since,X-Mimic-Token,X-Country-Code3,X-Postal-Code,X-Home-Postal-Code,X-Client-Postal,X-Station-Rights-Hash,DEVICE-PLATFORM,DEVICE-TYPE,DEVICE-MODEL,CLIENT-VERSION,DEVICE-ID,X-Preferred-Language,X-Dma,X-Supported-HDRModes-List,X-Supported-Codecs-List,X-Profile-Id,X-User-Id,X-User-Id-List,X-Client-Country,X-Device-Name,X-Device-Category,X-Device-Type,X-Device-Platform,X-Device-App,X-Device-Model,X-Device-Id,X-Client-Latitude,X-Client-Longitude,X-Client-Location-Precision,X-Client-Version,X-Player-Version,X-Playback-Capabilities,X-Device-Group,X-Supported-Streaming-Protocols,X-Modified-Since,X-Events-Token,X-Timezone-Offset,X-Sombra-Token,X-Transcend-Nonce,X-DRM-Scheme,X-App-Tracking-Authorization-Status,X-Is-Limited-Ad-Tracking,X-Advertising-Id,x-image-client-name,x-iab-store-region,x-iab-customer-id,x-iab-had-purchase,X-Session-Id,X-Ad-Id,X-Appsflyer-Id,X-Device-Manufacturer,X-Device-Brand,X-Lat-Enabled,X-Screen-Height,X-Screen-Width,X-Os,X-Os-Version,X-Browser,X-Browser-Version,X-Browser-Engine,X-Browser-Engine-Version,X-Segment-Anonymous-Id,X-Supported-Features,X-App-Source,X-Application-Id,X-Target-Device-Id,X-Accessibility-Enabled,X-SS-User-Id,customdata,soapaction,x-supported-audio-codecs,x-max-multiview-streams,X-Device-Manufacturer-Id,X-MFA-Token,x-iab-history,X-Hospitality-ID";
  set resp.http.Access-Control-Expose-Headers = "Content-Type,Content-Encoding,Cache-Control,Keep-Alive,X-Playhead-Ping-Interval,X-Request-Id,Date";
  set resp.http.Access-Control-Allow-Credentials = "true";

  if (req.method == "OPTIONS") {
    set resp.http.Access-Control-Allow-Methods = "GET, POST, PUT, DELETE, PATCH, OPTIONS";
    set resp.http.Access-Control-Allow-Origin = req.http.Origin;
    set resp.http.Access-Control-Expose-Headers = "X-GeoIP-Country-Code,X-Total";
    set resp.http.Access-Control-Max-Age = "1728000";

    set resp.http.Content-Type = "text/plain charset=UTF-8";
    set resp.reason = "OK";
    set resp.status = 200;
  }

  return(deliver);
}

"""#
}
