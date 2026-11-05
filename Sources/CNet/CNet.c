#include "CNet.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <poll.h>
#ifdef __APPLE__
#include <net/if_dl.h>
#else
#include <netpacket/packet.h>
#endif

static int fail(char *error, size_t n, const char *operation) {
    if (error && n) snprintf(error, n, "%s: %s", operation, strerror(errno));
    return -1;
}

int ch_list_adapters(ch_adapter *out, int capacity, char *error, size_t n) {
    struct ifaddrs *all = NULL;
    if (getifaddrs(&all) < 0) return fail(error,n,"getifaddrs");
    int count = 0;
    for (struct ifaddrs *p=all; p && count<capacity; p=p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || !(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        ch_adapter a; memset(&a,0,sizeof(a));
        snprintf(a.name,sizeof(a.name),"%s",p->ifa_name);
        a.index=if_nametoindex(p->ifa_name);
        inet_ntop(AF_INET,&((struct sockaddr_in *)p->ifa_addr)->sin_addr,a.address,sizeof(a.address));
        if (p->ifa_netmask) inet_ntop(AF_INET,&((struct sockaddr_in *)p->ifa_netmask)->sin_addr,a.netmask,sizeof(a.netmask));
        for (struct ifaddrs *q=all;q;q=q->ifa_next) {
            if (!q->ifa_addr || strcmp(q->ifa_name,p->ifa_name)) continue;
#ifdef __APPLE__
            if (q->ifa_addr->sa_family == AF_LINK) {
                struct sockaddr_dl *link=(struct sockaddr_dl *)q->ifa_addr;
                if (link->sdl_alen == 6) memcpy(a.mac,LLADDR(link),6);
            }
#else
            if (q->ifa_addr->sa_family == AF_PACKET) {
                struct sockaddr_ll *link=(struct sockaddr_ll *)q->ifa_addr;
                if (link->sll_halen == 6) memcpy(a.mac,link->sll_addr,6);
            }
#endif
        }
        uint8_t zero[6]={0};
        if (memcmp(a.mac,zero,6) == 0 || (a.mac[0] & 1)) continue;
        out[count++]=a;
    }
    freeifaddrs(all);
    return count;
}

int ch_udp_open(uint32_t index, uint16_t port, char *error, size_t n) {
    int fd=socket(AF_INET,SOCK_DGRAM,0);
    if (fd<0) return fail(error,n,"socket");
    int one=1;
    if (setsockopt(fd,SOL_SOCKET,SO_BROADCAST,&one,sizeof(one))<0) goto bad;
    /* Do NOT enable SO_REUSEADDR/PORT: only one configurator may own port 60000. */
#ifdef __APPLE__
    if (index && setsockopt(fd,IPPROTO_IP,IP_BOUND_IF,&index,sizeof(index))<0) goto bad;
#else
    (void)index; // Linux selects the interface per packet, without privileged SO_BINDTODEVICE.
    if (setsockopt(fd,IPPROTO_IP,IP_PKTINFO,&one,sizeof(one))<0) goto bad;
#endif
    struct sockaddr_in addr; memset(&addr,0,sizeof(addr));
#ifdef __APPLE__
    addr.sin_len=sizeof(addr);
#endif
    addr.sin_family=AF_INET; addr.sin_port=htons(port); addr.sin_addr.s_addr=htonl(INADDR_ANY);
    if (bind(fd,(struct sockaddr *)&addr,sizeof(addr))<0) goto bad;
    if (fcntl(fd,F_SETFL,fcntl(fd,F_GETFL,0) | O_NONBLOCK)<0) goto bad;
    if (fcntl(fd,F_SETFD,FD_CLOEXEC)<0) goto bad;
    return fd;
bad:
    { int e=errno; close(fd); errno=e; return fail(error,n,"open/bind UDP"); }
}

int ch_udp_send(int fd, uint32_t index, const char *source, const char *destination,
                uint16_t port, const uint8_t *bytes, size_t size, char *error, size_t n) {
    struct sockaddr_in dst; memset(&dst,0,sizeof(dst));
#ifdef __APPLE__
    dst.sin_len=sizeof(dst);
#endif
    dst.sin_family=AF_INET; dst.sin_port=htons(port);
    if (inet_pton(AF_INET,destination,&dst.sin_addr)!=1) { errno=EINVAL; return fail(error,n,"destination IPv4"); }
    ssize_t sent;
#ifdef __APPLE__
    /* IP_BOUND_IF constrains egress and ingress, including limited broadcasts. */
    (void)index; (void)source;
    sent=sendto(fd,bytes,size,0,(struct sockaddr *)&dst,sizeof(dst));
#else
    struct iovec iov={.iov_base=(void *)bytes,.iov_len=size};
    union { struct cmsghdr align; unsigned char bytes[CMSG_SPACE(sizeof(struct in_pktinfo))]; } control;
    memset(&control,0,sizeof(control));
    struct msghdr msg; memset(&msg,0,sizeof(msg));
    msg.msg_name=&dst; msg.msg_namelen=sizeof(dst); msg.msg_iov=&iov; msg.msg_iovlen=1;
    if (index) {
        msg.msg_control=control.bytes; msg.msg_controllen=sizeof(control.bytes);
        struct cmsghdr *cmsg=CMSG_FIRSTHDR(&msg);
        cmsg->cmsg_level=IPPROTO_IP; cmsg->cmsg_type=IP_PKTINFO; cmsg->cmsg_len=CMSG_LEN(sizeof(struct in_pktinfo));
        struct in_pktinfo *info=(struct in_pktinfo *)CMSG_DATA(cmsg);
        info->ipi_ifindex=(int)index;
        if (inet_pton(AF_INET,source,&info->ipi_spec_dst)!=1) { errno=EINVAL; return fail(error,n,"source IPv4"); }
    }
    sent=sendmsg(fd,&msg,0);
#endif
    if (sent<0) return fail(error,n,"send UDP");
    if ((size_t)sent != size) { errno=EIO; return fail(error,n,"short UDP send"); }
    return (int)sent;
}

int ch_udp_receive(int fd, uint32_t index, uint8_t *bytes, size_t capacity,
                   int timeout_ms, uint16_t *source_port, char *source_ip,
                   char *error, size_t n) {
    struct pollfd p={.fd=fd,.events=POLLIN};
    int ready=poll(&p,1,timeout_ms);
    if (ready==0 || (ready<0 && errno==EINTR)) return 0;
    if (ready<0) return fail(error,n,"poll UDP");
    struct sockaddr_in src; memset(&src,0,sizeof(src));
    struct iovec iov={.iov_base=bytes,.iov_len=capacity};
    union { struct cmsghdr align; unsigned char bytes[256]; } control;
    memset(&control,0,sizeof(control));
    struct msghdr msg; memset(&msg,0,sizeof(msg));
    msg.msg_name=&src; msg.msg_namelen=sizeof(src); msg.msg_iov=&iov; msg.msg_iovlen=1;
    msg.msg_control=control.bytes; msg.msg_controllen=sizeof(control.bytes);
    ssize_t got=recvmsg(fd,&msg,0);
    if (got<0 && (errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR)) return 0;
    if (got<0) return fail(error,n,"receive UDP");
    if (msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) return 0;
#ifndef __APPLE__
    if (index) {
        int matched=0;
        for (struct cmsghdr *c=CMSG_FIRSTHDR(&msg);c;c=CMSG_NXTHDR(&msg,c)) {
            if (c->cmsg_level==IPPROTO_IP && c->cmsg_type==IP_PKTINFO && c->cmsg_len>=CMSG_LEN(sizeof(struct in_pktinfo))) {
                struct in_pktinfo *info=(struct in_pktinfo *)CMSG_DATA(c);
                matched=((uint32_t)info->ipi_ifindex==index);
            }
        }
        if (!matched) return 0;
    }
#else
    (void)index;
#endif
    *source_port=ntohs(src.sin_port);
    inet_ntop(AF_INET,&src.sin_addr,source_ip,16);
    return (int)got;
}
uint16_t ch_udp_local_port(int fd) {
    struct sockaddr_in a; socklen_t n=sizeof(a);
    return getsockname(fd,(struct sockaddr *)&a,&n)==0 ? ntohs(a.sin_port) : 0;
}
void ch_udp_close(int fd) { if (fd>=0) close(fd); }
