ARG PROSODY_IMAGE=prosodyim/prosody:0.12
FROM ${PROSODY_IMAGE}
COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["prosody"]
